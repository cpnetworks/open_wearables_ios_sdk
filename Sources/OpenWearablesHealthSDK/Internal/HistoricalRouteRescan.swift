import Foundation
import HealthKit

/// Sole Mates WP #30 (2026-10-08) - Historical GPS Route Recovery, Apple
/// Health track.
///
/// Requires a new SDK release and a new My Sole Sync app build before any
/// of this can run on a real device - see this file's own report. There
/// is no server-side equivalent: HealthKit has no cloud API, so recovery
/// can only ever be initiated on-device, by this SDK, while the user has
/// HealthKit authorization granted on their own phone.
///
/// Deliberately reuses, unchanged, the exact two things that already
/// handle this correctly for a NEW workout:
///   - `fetchRoutePayload(for:)` - queries `HKSeriesType.workoutRoute()`
///     by the workout's own identity (`HKQuery.predicateForObjects(from:)`),
///     which works identically for a workout from five minutes ago or
///     five months ago. A miss here is reported honestly as "no route
///     found," never recorded as a Stage-F pending retry (that queue
///     exists for a SHORT timing race on a workout actively being
///     synced right now - a historical rescan's "miss" after the fact is
///     not that race; see fetchRoutePayload's own doc comment for why
///     the two cases must stay distinct).
///   - `buildCombinedPayload`/`uploadCombinedPayload` - the SAME resend
///     mechanism RouteRetry.swift already uses. The server's existing
///     natural-key resolution (`EventRecordRepository.get_by_source_and_window`,
///     via import_service.py's `_resolve_event_for_route`) attaches the
///     now-found route to the SAME EventRecord; `bulk_create`'s
///     `ON CONFLICT DO NOTHING` guarantees this can never create a
///     second EventRecord. No new server code, no new wire format.
///
/// What IS new here: enumerating historical `HKWorkout`s at all (ordinary
/// sync is anchor-based, forward-only, and never revisits an already-
/// synced workout) and doing it resumably, with pause/cancel, bounded to
/// exactly the window this installation has already imported.
///
/// Scope boundary (WP #30 locked decision - "do not expand the historical
/// workout-import window without separate approval"): this rescans
/// EXACTLY the window `syncStartDate()` already defines for ordinary
/// sync on this device - never further back. Resending a workout this
/// installation already uploaded is safe (idempotent, natural-key
/// resolved); resending one it never uploaded would be an unauthorized
/// expansion of what this installation imports, not a route recovery.
extension OpenWearablesHealthSDK {

    // MARK: - Progress model

    public enum HistoricalRescanStatus: String, Codable {
        case notStarted
        case running
        case paused
        case cancelled
        case completed
    }

    public struct HistoricalRescanProgress: Codable, Equatable {
        public internal(set) var status: HistoricalRescanStatus
        /// nil until the first chunk completes; thereafter the oldest
        /// `endDate` boundary already examined - the resumable cursor.
        public internal(set) var olderThanCursor: Date?
        public internal(set) var scannedCount: Int
        public internal(set) var routeFoundCount: Int
        public internal(set) var resentCount: Int
        public internal(set) var resendFailedCount: Int

        static let notStartedValue = HistoricalRescanProgress(
            status: .notStarted, olderThanCursor: nil, scannedCount: 0,
            routeFoundCount: 0, resentCount: 0, resendFailedCount: 0
        )
    }

    // MARK: - Persisted state
    //
    // Test seams (historicalRescanEnumerationOverrideForTests,
    // historicalRescanRouteLookupOverrideForTests) are real stored
    // properties declared on the main class in OpenWearablesHealthSDK.swift
    // — mirroring routeRetryLookupOverrideForTests's own placement — not
    // here, since Swift extensions cannot declare stored properties.

    private func historicalRescanStateFileURL() -> URL {
        stateBaseDirectory().appendingPathComponent("historical_route_rescan_state.json")
    }

    public func historicalRouteRescanProgress() -> HistoricalRescanProgress {
        guard let data = try? Data(contentsOf: historicalRescanStateFileURL()),
              let progress = try? JSONDecoder().decode(HistoricalRescanProgress.self, from: data) else {
            return .notStartedValue
        }
        return progress
    }

    private func saveHistoricalRescanProgress(_ progress: HistoricalRescanProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: historicalRescanStateFileURL(), options: .atomic)
    }

    // MARK: - Public control surface

    /// Starts a new rescan, or resumes one already in progress — the
    /// persisted `olderThanCursor` makes these the same operation.
    /// Interrupting the app (killed, backgrounded past its budget) and
    /// calling this again later picks up exactly where the last
    /// completed chunk left off; nothing is lost except the
    /// in-flight-but-uncompleted chunk, which is itself safe to redo
    /// (both fetchRoutePayload and the resend path are idempotent).
    public func startHistoricalRouteRescan(completion: @escaping (HistoricalRescanProgress) -> Void) {
        var progress = historicalRouteRescanProgress()
        if progress.status == .completed {
            completion(progress)
            return
        }
        guard let endpoint = self.syncEndpoint, let credential = self.authCredential else {
            logMessage("Historical route rescan cannot start: not signed in")
            completion(progress)
            return
        }
        guard let generation = beginSyncRun() else {
            logMessage("Historical route rescan deferred: ordinary sync is in progress")
            completion(progress)
            return
        }
        progress.status = .running
        saveHistoricalRescanProgress(progress)
        runHistoricalRescanChunk(
            olderThan: progress.olderThanCursor,
            endpoint: endpoint, credential: credential, generation: generation, completion: completion
        )
    }

    /// Cooperative — takes effect once the in-flight chunk finishes,
    /// never mid-chunk, so a pause always lands on a clean checkpoint.
    public func pauseHistoricalRouteRescan() {
        var progress = historicalRouteRescanProgress()
        guard progress.status == .running else { return }
        progress.status = .paused
        saveHistoricalRescanProgress(progress)
    }

    /// Distinct from pause: a cancelled rescan's cursor is preserved
    /// (so the operator can see exactly how far it got) but will only
    /// ever resume via an explicit startHistoricalRouteRescan() call —
    /// nothing auto-resumes a cancelled run.
    public func cancelHistoricalRouteRescan() {
        var progress = historicalRouteRescanProgress()
        guard progress.status == .running || progress.status == .paused else { return }
        progress.status = .cancelled
        saveHistoricalRescanProgress(progress)
    }

    // MARK: - Chunked driver

    private static let rescanChunkLimit = 20

    private func runHistoricalRescanChunk(
        olderThan: Date?,
        endpoint: URL, credential: String, generation: Int,
        completion: @escaping (HistoricalRescanProgress) -> Void
    ) {
        // Re-read from disk on every chunk boundary — pause/cancel write
        // directly to disk from whatever thread called them, and this is
        // the one moment between chunks where that write must be observed.
        if historicalRouteRescanProgress().status != .running || isSyncCancelled(generation: generation) {
            finishSync(generation: generation)
            completion(historicalRouteRescanProgress())
            return
        }

        fetchOneHistoricalWorkoutChunk(olderThan: olderThan, lowerBound: syncStartDate()) { [weak self] success, workouts, nextOlderThan, isDone in
            guard let self = self else { return }
            if !success {
                self.finishSync(generation: generation, outcome: .failedQuery)
                completion(self.historicalRouteRescanProgress())
                return
            }
            self.processHistoricalRescanWorkouts(
                workouts, index: 0,
                endpoint: endpoint, credential: credential, generation: generation
            ) {
                var updated = self.historicalRouteRescanProgress()
                updated.olderThanCursor = nextOlderThan
                if isDone {
                    updated.status = .completed
                    self.saveHistoricalRescanProgress(updated)
                    self.finishSync(generation: generation)
                    completion(updated)
                    return
                }
                self.saveHistoricalRescanProgress(updated)
                self.runHistoricalRescanChunk(
                    olderThan: nextOlderThan,
                    endpoint: endpoint, credential: credential, generation: generation, completion: completion
                )
            }
        }
    }

    private func processHistoricalRescanWorkouts(
        _ workouts: [HKWorkout], index: Int,
        endpoint: URL, credential: String, generation: Int, done: @escaping () -> Void
    ) {
        guard index < workouts.count, !isSyncCancelled(generation: generation) else {
            done()
            return
        }
        let workout = workouts[index]
        routePayload(for: workout) { [weak self] payload in
            guard let self = self else { return }
            var current = self.historicalRouteRescanProgress()
            current.scannedCount += 1

            guard let payload = payload, !payload.isEmpty else {
                self.saveHistoricalRescanProgress(current)
                self.processHistoricalRescanWorkouts(
                    workouts, index: index + 1,
                    endpoint: endpoint, credential: credential, generation: generation, done: done
                )
                return
            }
            current.routeFoundCount += 1
            self.saveHistoricalRescanProgress(current)

            let payloadDict = self.buildCombinedPayload(samples: [workout], routesByWorkoutId: [workout.uuid: payload])
            self.uploadCombinedPayload(
                payload: payloadDict, endpoint: endpoint, credential: credential, generation: generation
            ) { success in
                var afterUpload = self.historicalRouteRescanProgress()
                if success {
                    afterUpload.resentCount += 1
                } else {
                    // A network/auth failure here is not "no route" — leave
                    // it for a later rescan pass to pick back up rather
                    // than silently losing it; still advances past this
                    // workout in THIS run so one flaky resend can't stall
                    // the whole chunk.
                    afterUpload.resendFailedCount += 1
                }
                self.saveHistoricalRescanProgress(afterUpload)
                self.processHistoricalRescanWorkouts(
                    workouts, index: index + 1,
                    endpoint: endpoint, credential: credential, generation: generation, done: done
                )
            }
        }
    }

    private func routePayload(for workout: HKWorkout, completion: @escaping ([[String: Any]]?) -> Void) {
        if let override = historicalRescanRouteLookupOverrideForTests {
            override(workout, completion)
            return
        }
        fetchRoutePayload(for: workout, completion: completion)
    }

    private func fetchOneHistoricalWorkoutChunk(
        olderThan: Date?, lowerBound: Date?,
        completion: @escaping (Bool, [HKWorkout], Date?, Bool) -> Void
    ) {
        if let override = historicalRescanEnumerationOverrideForTests {
            override(olderThan, lowerBound, Self.rescanChunkLimit, completion)
            return
        }

        var predicate: NSPredicate?
        if let olderThan = olderThan {
            predicate = HKQuery.predicateForSamples(withStart: lowerBound, end: olderThan, options: .strictEndDate)
        } else {
            predicate = HKQuery.predicateForSamples(withStart: lowerBound, end: nil, options: [])
        }

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: .workoutType(), predicate: predicate, limit: Self.rescanChunkLimit, sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samplesOrNil, error in
            guard let self = self else { completion(false, [], nil, false); return }

            if let error = error {
                self.logMessage("Historical route rescan query failed: \(error.localizedDescription)")
                completion(false, [], nil, false)
                return
            }

            let workouts = (samplesOrNil as? [HKWorkout]) ?? []
            if workouts.isEmpty {
                completion(true, [], nil, true)
                return
            }
            let isLastChunk = workouts.count < Self.rescanChunkLimit
            let nextOlderThan = isLastChunk ? nil : workouts.last!.endDate
            completion(true, workouts, nextOlderThan, isLastChunk)
        }
        healthStore.execute(query)
    }
}
