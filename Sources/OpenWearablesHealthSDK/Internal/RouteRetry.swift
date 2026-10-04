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

    /// Minimum elapsed time (since `lastAttemptAt`, or `firstMissedAt` if
    /// never attempted) before attempt N is eligible. Not derived from the
    /// single 27-minute diagnostic observation - deliberately front-loaded
    /// so the common case (route finishes writing within a minute or two,
    /// while the user is still actively using the phone right after a
    /// workout) resolves via the ordinary observer-driven syncs that are
    /// already firing repeatedly in that window, with the longer steps as
    /// a backstop for the slow/backgrounded case.
    internal static let routeRetryBackoff: [TimeInterval] = [15, 60, 300, 1800]

    /// Attempts that actually queried HealthKit and found nothing. A skip
    /// (protected data unavailable, or a resend that failed for network
    /// reasons) must not count against this - see `handleRouteRetryLookupResult`.
    internal static let routeRetryMaxAttempts = routeRetryBackoff.count

    /// Hard backstop independent of attemptCount, so a pending route that
    /// never gets another sync opportunity (app never reopened) does not
    /// stay pending forever.
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

    internal func isRouteRetryEligibleNow(_ item: PendingRouteRetry, now: Date = Date()) -> Bool {
        let step = min(item.attemptCount, Self.routeRetryBackoff.count - 1)
        let base = item.lastAttemptAt ?? item.firstMissedAt
        return now.timeIntervalSince(base) >= Self.routeRetryBackoff[step]
    }

    internal func isRouteRetryExpired(_ item: PendingRouteRetry, now: Date = Date()) -> Bool {
        item.attemptCount >= Self.routeRetryMaxAttempts || now.timeIntervalSince(item.firstMissedAt) >= Self.routeRetryMaxAge
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
