import Foundation
import HealthKit
import UIKit

/// Map Roadmap #27 Stage F - Apple Route Availability Race Remediation.
///
/// Root cause (confirmed via a real-device diagnostic, 2026-10-04): a
/// workout's `HKWorkoutRoute` is not always locally available in
/// HealthKit's store the instant the parent `HKWorkout` is delivered via
/// the anchored/observer sync - on one real Apple Watch recording the
/// route was still missing 4.6s after the workout ended but fully present
/// ~27 minutes later. `fetchRoutePayload` queried too early and the
/// workout's anchor had already advanced by the time the route existed,
/// so an ordinary incremental sync never revisits that workout - a single
/// early miss was permanently and silently treated as "no route."
///
/// This file adds a small, persisted, bounded retry queue so a genuine
/// timing miss gets another chance without ever delaying or gating the
/// workout's own prompt sync (see `fetchRoutePayload`'s own doc comment -
/// that is unchanged, this is purely additive). There is no server
/// change: a later resend of the SAME workout (same DataSource + start +
/// end - the natural key `EventRecordRepository.get_by_source_and_window`
/// already resolves on) with its route now attached is already
/// idempotently attached to the SAME EventRecord server-side - see the
/// backend's own `TestExistingWorkoutLaterRoute`/`TestIdempotency`
/// coverage, reused unchanged.
///
/// Deliberately event-driven, never timer-based: iOS gives no guaranteed
/// sub-minute background timer, so each backoff step is a MINIMUM
/// eligibility floor checked opportunistically whenever something else
/// already has a reason to run (an HK observer firing, foreground,
/// device unlock, a BGProcessingTask) - mirrors `retryOutboxIfPossible`'s
/// own "piggyback on an existing wake" pattern in Outbox.swift.
extension OpenWearablesHealthSDK {

    // MARK: - Pending route retry model

    internal struct PendingRouteRetry: Codable, Equatable {
        let workoutUUID: UUID
        let firstMissedAt: Date
        var lastAttemptAt: Date?
        var attemptCount: Int
    }

    /// Map Roadmap #27 Stage G (2026-10-04) - attempt count controls ONLY
    /// retry cadence; wall-clock age alone controls terminal
    /// classification. Stage F's bounded proof found the real remediation
    /// sound but its original "4 attempts OR 24h" termination conflated
    /// the two: with triggers firing as fast as device-unlock/foreground,
    /// 4 attempts can exhaust in well under an hour - nowhere near proving
    /// genuine route absence, when the only two real timing samples on
    /// hand are a 27-minute natural case and a 45s forced-miss case. A
    /// route must never go terminal merely because a handful of early,
    /// closely-spaced queries came back empty.
    ///
    /// Early phase: the same 15s/1m/5m/30m floors as before, so the
    /// common case (route finishes writing within a minute or two, user
    /// still has the phone in hand) is unchanged. Once attemptCount
    /// reaches `routeRetryEarlyBackoff.count`, the item moves into a slow
    /// phase with a flat ~hourly floor - frequent opportunistic triggers
    /// (foreground, unlock, observer) keep arriving but a trigger inside
    /// that hour is simply not eligible, so it causes zero additional
    /// HealthKit queries. This is the simplest rule that fits the
    /// existing persisted queue unchanged: one more branch in the same
    /// eligibility function, no new fields, no new storage.
    internal static let routeRetryEarlyBackoff: [TimeInterval] = [15, 60, 300, 1800]

    /// Flat eligibility floor once the early phase is exhausted - frequent
    /// enough to still resolve well within the 24h window, coarse enough
    /// that no realistic trigger frequency can turn it into HealthKit
    /// hammering.
    internal static let routeRetrySlowPhaseInterval: TimeInterval = 3600

    /// The ONLY terminal criterion. Deliberately conservative and
    /// provisional for production v1 - see this file's own header on
    /// Stage F's two real timing samples being too few to tune this
    /// further yet.
    internal static let routeRetryMaxAge: TimeInterval = 24 * 3600

    private func pendingRouteRetryFileURL() -> URL {
        stateBaseDirectory().appendingPathComponent("pending_apple_route_retries.json")
    }

    internal func loadPendingRouteRetries() -> [PendingRouteRetry] {
        guard let data = try? Data(contentsOf: pendingRouteRetryFileURL()),
              let items = try? JSONDecoder().decode([PendingRouteRetry].self, from: data) else {
            return []
        }
        return items
    }

    private func savePendingRouteRetries(_ items: [PendingRouteRetry]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: pendingRouteRetryFileURL(), options: .atomic)
    }

    /// Called only from `fetchRoutePayload`'s genuine-miss branch - never
    /// from the retry path itself, so a repeat miss during retry does not
    /// reset `firstMissedAt`. A no-op if this workout is already tracked.
    internal func recordPendingRouteRetryIfNeeded(for workout: HKWorkout) {
        var items = loadPendingRouteRetries()
        guard !items.contains(where: { $0.workoutUUID == workout.uuid }) else { return }
        items.append(PendingRouteRetry(workoutUUID: workout.uuid, firstMissedAt: Date(), lastAttemptAt: nil, attemptCount: 0))
        savePendingRouteRetries(items)
        logMessage("Route pending retry recorded for workout \(workout.uuid.uuidString)")
    }

    /// Attempt count picks the floor (early backoff step, or the flat slow-
    /// phase interval once the early steps are exhausted) - it never
    /// decides whether the item is still alive, only how soon it may be
    /// checked again.
    internal func isRouteRetryEligibleNow(_ item: PendingRouteRetry, now: Date = Date()) -> Bool {
        let floor: TimeInterval
        if item.attemptCount < Self.routeRetryEarlyBackoff.count {
            floor = Self.routeRetryEarlyBackoff[item.attemptCount]
        } else {
            floor = Self.routeRetrySlowPhaseInterval
        }
        let base = item.lastAttemptAt ?? item.firstMissedAt
        return now.timeIntervalSince(base) >= floor
    }

    /// Wall-clock age since `firstMissedAt` is the ONLY terminal
    /// criterion - attemptCount plays no part. A skipped check (protected
    /// data unavailable, or a resend that failed for network reasons)
    /// never advances `lastAttemptAt`/`attemptCount` (see
    /// `handleRouteRetryLookupResult`), so it can only ever bring an item
    /// closer to this age-based expiry by the passage of real time, the
    /// same as a genuine miss would - never prematurely.
    internal func isRouteRetryExpired(_ item: PendingRouteRetry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(item.firstMissedAt) >= Self.routeRetryMaxAge
    }

    /// Opportunistic drain of the pending-route queue. A no-op when there
    /// is nothing pending, nothing eligible yet, protected data is
    /// unavailable (device locked - HealthKit queries would fail, and
    /// this must not consume a retry attempt for that), or a real sync is
    /// already running (shares `beginSyncRun`'s mutual-exclusion slot so a
    /// retry resend can never race a normal sync's own upload).
    internal func retryPendingRoutesIfPossible() {
        let protectedDataAvailable = protectedDataAvailableOverrideForTests ?? UIApplication.shared.isProtectedDataAvailable
        guard protectedDataAvailable else {
            logMessage("Route retry skipped - protected data unavailable")
            return
        }
        guard let endpoint = self.syncEndpoint, let credential = self.authCredential else { return }

        var items = loadPendingRouteRetries()
        guard !items.isEmpty else { return }

        let now = Date()
        let expired = items.filter { isRouteRetryExpired($0, now: now) }
        if !expired.isEmpty {
            let expiredIds = Set(expired.map { $0.workoutUUID })
            items.removeAll { expiredIds.contains($0.workoutUUID) }
            savePendingRouteRetries(items)
            logMessage("Route retry: \(expired.count) pending route(s) exhausted retries - leaving last known status")
        }

        let due = items.filter { isRouteRetryEligibleNow($0, now: now) }
        guard !due.isEmpty else { return }

        guard let generation = beginSyncRun() else {
            logMessage("Route retry skipped - sync in progress")
            return
        }

        attemptRouteRetries(due, index: 0, endpoint: endpoint, credential: credential, generation: generation)
    }

    private func attemptRouteRetries(
        _ items: [PendingRouteRetry], index: Int, endpoint: URL, credential: String, generation: Int
    ) {
        guard index < items.count, !isSyncCancelled(generation: generation) else {
            finishSync(generation: generation)
            return
        }

        let item = items[index]
        lookupWorkoutAndRoute(uuid: item.workoutUUID) { [weak self] workout, routePayload in
            guard let self = self else { return }
            self.handleRouteRetryLookupResult(
                item: item, workout: workout, routePayload: routePayload,
                endpoint: endpoint, credential: credential, generation: generation
            ) {
                self.attemptRouteRetries(items, index: index + 1, endpoint: endpoint, credential: credential, generation: generation)
            }
        }
    }

    /// The only piece of the retry path that touches real HealthKit -
    /// refetches the `HKWorkout` by its own UUID (never a time/distance
    /// re-match, same identity discipline as the rest of #27) and queries
    /// its route via the existing `fetchRoutePayload`. Overridable in
    /// tests, since a workout built with `HKWorkout`'s in-memory
    /// initializer was never actually saved to the store a real query
    /// would hit.
    private func lookupWorkoutAndRoute(uuid: UUID, completion: @escaping (HKWorkout?, [[String: Any]]?) -> Void) {
        if let override = routeRetryLookupOverrideForTests {
            override(uuid, completion)
            return
        }
        let workoutPredicate = HKQuery.predicateForObject(with: uuid)
        let workoutQuery = HKSampleQuery(
            sampleType: .workoutType(), predicate: workoutPredicate, limit: 1, sortDescriptors: nil
        ) { [weak self] _, samplesOrNil, _ in
            guard let self = self else { completion(nil, nil); return }
            guard let workout = (samplesOrNil as? [HKWorkout])?.first else {
                completion(nil, nil)
                return
            }
            self.fetchRoutePayload(for: workout) { payload in
                completion(workout, payload)
            }
        }
        healthStore.execute(workoutQuery)
    }

    /// Pure state-transition logic given an already-resolved lookup
    /// result - no HealthKit access here, so this is the part unit tests
    /// exercise directly via `routeRetryLookupOverrideForTests`.
    private func handleRouteRetryLookupResult(
        item: PendingRouteRetry, workout: HKWorkout?, routePayload: [[String: Any]]?,
        endpoint: URL, credential: String, generation: Int, done: @escaping () -> Void
    ) {
        guard let workout = workout else {
            // The workout itself is gone from HealthKit (user deleted it) -
            // nothing left to retry.
            removePendingRouteRetry(item.workoutUUID)
            done()
            return
        }
        guard let routePayload = routePayload, !routePayload.isEmpty else {
            markRouteRetryAttempted(item.workoutUUID)
            done()
            return
        }
        resendWorkoutWithRoute(
            workout: workout, routePayload: routePayload, endpoint: endpoint, credential: credential, generation: generation
        ) { [weak self] success in
            guard let self = self else { done(); return }
            if success {
                self.removePendingRouteRetry(item.workoutUUID)
                self.logMessage("Route retry: late route attached for workout \(item.workoutUUID.uuidString)")
            } else {
                // A network/auth failure sending the resend is not "no
                // route yet" - must not consume a backoff step, so the
                // same workout is retried at the SAME eligibility time on
                // the next opportunity.
                self.logMessage("Route retry: resend failed for workout \(item.workoutUUID.uuidString), will retry")
            }
            done()
        }
    }

    private func markRouteRetryAttempted(_ uuid: UUID) {
        var items = loadPendingRouteRetries()
        guard let idx = items.firstIndex(where: { $0.workoutUUID == uuid }) else { return }
        items[idx].attemptCount += 1
        items[idx].lastAttemptAt = Date()
        savePendingRouteRetries(items)
    }

    private func removePendingRouteRetry(_ uuid: UUID) {
        var items = loadPendingRouteRetries()
        items.removeAll { $0.workoutUUID == uuid }
        savePendingRouteRetries(items)
    }

    /// Resends exactly one already-synced workout, now with its route,
    /// through the same `buildCombinedPayload`/`uploadCombinedPayload`
    /// used by every ordinary sync round - no new wire format. The
    /// server's existing natural-key CASE B resolution
    /// (`EventRecordRepository.get_by_source_and_window`, via
    /// `import_service.py`'s `_resolve_event_for_route`) attaches this to
    /// the SAME EventRecord; `bulk_create`'s `ON CONFLICT DO NOTHING`
    /// guarantees no second EventRecord is ever created by this resend.
    private func resendWorkoutWithRoute(
        workout: HKWorkout, routePayload: [[String: Any]], endpoint: URL, credential: String, generation: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let payload = buildCombinedPayload(samples: [workout], routesByWorkoutId: [workout.uuid: routePayload])
        uploadCombinedPayload(payload: payload, endpoint: endpoint, credential: credential, generation: generation) { success in
            completion(success)
        }
    }
}
