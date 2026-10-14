import Foundation
import HealthKit

/// Sole Mates Gate H.32 (2026-10-13) - Historical Workout-Statistics
/// Recovery, Apple Health track.
///
/// Companion to `HistoricalRouteRescan.swift` (WP #30), same shape and
/// same safety discipline, for a different HealthKit gap: `_buildWorkoutStats`
/// (Types.swift) reads distance, heart rate, power, cadence, speed,
/// step count and several other metrics via `HKWorkout.statistics(for:)`,
/// which returns `nil` whenever the host app lacks read authorization
/// for that SPECIFIC quantity type - a state HealthKit makes genuinely
/// indistinguishable from "no data exists" by design (see
/// `HKHealthStore.authorizationStatus(for:)`'s own documentation: for
/// read-only types it cannot reliably report denied vs. not-yet-determined,
/// precisely so an app can never probe what a user is hiding). A user who
/// grants only a SUBSET of these types at onboarding, then expands that
/// grant later, ends up with already-synced workouts permanently missing
/// whatever metric wasn't yet authorized at sync time - ordinary sync is
/// anchor-based and forward-only (`Anchors.swift`) and never revisits an
/// already-synced `HKWorkout`, and granting a new permission does not,
/// by itself, cause HealthKit or this SDK to re-deliver one.
///
/// Reuses, unchanged, both of the things that already do the hard part
/// correctly for a brand-new workout:
///   - `fetchOneHistoricalWorkoutChunk` (HistoricalRouteRescan.swift) -
///     the SAME bounded, resumable HKWorkout enumeration, and its own
///     test seam (`historicalRescanEnumerationOverrideForTests`). There
///     is nothing route-specific about enumerating historical workouts;
///     only what happens per workout differs between the two rescans.
///   - `buildCombinedPayload`/`uploadCombinedPayload` - the SAME resend
///     mechanism live sync and the route rescan both use.
///     `buildCombinedPayload` always reads a workout's stats from
///     whatever HealthKit currently allows, not from what was true at
///     the ORIGINAL sync time - so simply resending is itself the
///     recovery mechanism; no separate "has this permission really
///     expanded" HealthKit probe is needed or attempted per workout.
///     The workout's `"id"` field is `HKWorkout.uuid.uuidString`
///     (`_mapWorkoutEfficient`, Types.swift) - unchanged by a resend, so
///     the server's identity match is exact, never heuristic.
///
/// Unlike the route rescan, there is no per-workout "outcome" to
/// classify: a route fetch is a separate HealthKit query that can itself
/// fail (query error, authorization denial) independently of the workout
/// object already in hand; workout statistics are read directly off the
/// `HKWorkout` object this rescan already holds via `.statistics(for:)`,
/// which never throws and never distinguishes "denied" from "absent" -
/// it just returns nil either way. So every enumerated workout is simply
/// resent; there is nothing analogous to `.noRouteObjectsPresent` /
/// `.queryFailed` / `.failedAuthorization` to detect here, and no
/// `noRouteConfirmedCount`-style bookkeeping is possible or meaningful.
///
/// Scope boundary (same locked decision as WP #30 - "do not expand the
/// historical workout-import window without separate approval"): this
/// rescans EXACTLY the window `syncStartDate()` already defines for
/// ordinary sync on this device, bounded further by an explicit
/// `maxWorkouts` cap per invocation. If `syncStartDate()` returns nil
/// (no finite `syncDaysBack` configured), this refuses to start -
/// `.refusedUnboundedWindow` - before touching HealthKit at all, exactly
/// like the route rescan. This file never calls `resetAnchors()` /
/// `resetAllAnchors()` and never reads or writes anything in
/// `Anchors.swift` - confirmed by construction, not merely by intent:
/// grep this file for "Anchor" and "resetAnchors" to re-verify after any
/// future edit.
///
/// What a resend CANNOT fix by itself: the OW backend's detail-row
/// upsert (`EventRecordDetailRepository.bulk_create`'s `ON CONFLICT DO
/// UPDATE`) sets every detail column unconditionally from whatever this
/// resend's payload carries - a resend that newly includes distance but,
/// for any reason, omits a metric that was previously stored (e.g. a
/// HealthKit sample genuinely no longer present) would null that field
/// out server-side. This SDK has no way to read back what the server
/// currently has, so it cannot protect against that from the client
/// side; the corresponding backend fix is tracked separately (Gate H.32
/// Part 2, `event_record_detail_repository.py`) and is a hard
/// prerequisite for this rescan to be safe to run against production -
/// see that gate's report for the exact null-safe-merge patch and why
/// production does not even have the identity-matched correction path
/// this depends on yet.
extension OpenWearablesHealthSDK {

    // MARK: - Progress model

    public enum HistoricalStatsRescanStatus: String, Codable {
        case notStarted
        case running
        case paused
        case cancelled
        case completed
        /// This installation has no finite `syncDaysBack` configured
        /// (`syncStartDate()` returned nil) - refused before touching
        /// HealthKit at all, exactly like the route rescan's identical
        /// case. No override; configure a finite `syncDaysBack` first.
        case refusedUnboundedWindow
        /// Stopped after reaching the caller-supplied `maxWorkouts` for
        /// this invocation, not because the window was exhausted.
        /// Resumable the same way as the route rescan: call
        /// `startHistoricalWorkoutStatsRescan` again.
        case stoppedAtWorkoutLimit
        /// The workout-enumeration query itself failed. `olderThanCursor`
        /// is unchanged; retry by calling `startHistoricalWorkoutStatsRescan`
        /// again - see `HistoricalRescanStatus.failedEnumerationQuery`'s
        /// own doc comment for why this must be a real terminal status,
        /// never a stuck `.running`.
        case failedEnumerationQuery
    }

    public struct HistoricalStatsRescanProgress: Codable, Equatable {
        public internal(set) var status: HistoricalStatsRescanStatus
        /// nil until the first chunk completes; thereafter the oldest
        /// `endDate` boundary already examined - the resumable cursor.
        public internal(set) var olderThanCursor: Date?
        public internal(set) var scannedCount: Int
        public internal(set) var resentCount: Int
        /// A network/auth failure on this ONE workout's resend - left
        /// for a later invocation to retry; does not halt the run (one
        /// flaky resend must not stall the whole chunk).
        public internal(set) var resendFailedCount: Int

        static let notStartedValue = HistoricalStatsRescanProgress(
            status: .notStarted, olderThanCursor: nil, scannedCount: 0,
            resentCount: 0, resendFailedCount: 0
        )
    }

    // MARK: - Persisted state

    private func historicalStatsRescanStateFileURL() -> URL {
        stateBaseDirectory().appendingPathComponent("historical_workout_stats_rescan_state.json")
    }

    public func historicalWorkoutStatsRescanProgress() -> HistoricalStatsRescanProgress {
        guard let data = try? Data(contentsOf: historicalStatsRescanStateFileURL()),
              let progress = try? JSONDecoder().decode(HistoricalStatsRescanProgress.self, from: data) else {
            return .notStartedValue
        }
        return progress
    }

    private func saveHistoricalStatsRescanProgress(_ progress: HistoricalStatsRescanProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: historicalStatsRescanStateFileURL(), options: .atomic)
    }

    // MARK: - Public control surface

    /// Default cap on how many workouts ONE invocation will scan. Same
    /// rationale as the route rescan's own default: exists only so the
    /// parameter has a safe, non-infinite value, never as a
    /// recommendation - a real rollout should pass an explicit, smaller
    /// cap.
    public static let defaultMaxWorkoutsPerHistoricalStatsRescanInvocation = 200

    /// Starts a new stats rescan, or resumes one already in progress -
    /// the persisted `olderThanCursor` makes these the same operation.
    /// Call this explicitly (e.g. a support-driven repair for a specific
    /// user) at any time; it is also called automatically by
    /// `requestAuthorization` when it detects the host app just asked
    /// for a strict superset of the previously-tracked types - see that
    /// method's own doc comment for why detecting "permission expanded"
    /// is done that way, never via a direct HealthKit authorization-status
    /// probe, and what the fallback is when it can't be determined.
    ///
    /// Same two mandatory bounds as `startHistoricalRouteRescan`:
    ///   - This installation must have a FINITE sync window
    ///     (`syncStartDate()` non-nil). Otherwise refused outright -
    ///     `.refusedUnboundedWindow` - before any HealthKit query runs.
    ///   - `maxWorkouts` caps how many workouts THIS invocation scans.
    ///     Reaching it stops the run cleanly (`.stoppedAtWorkoutLimit`,
    ///     resumable exactly like a pause).
    public func startHistoricalWorkoutStatsRescan(
        maxWorkouts: Int = defaultMaxWorkoutsPerHistoricalStatsRescanInvocation,
        completion: @escaping (HistoricalStatsRescanProgress) -> Void
    ) {
        var progress = historicalWorkoutStatsRescanProgress()
        if progress.status == .completed {
            completion(progress)
            return
        }
        guard maxWorkouts > 0 else {
            logMessage("Historical workout-stats rescan cannot start: maxWorkouts must be positive, got \(maxWorkouts)")
            completion(progress)
            return
        }
        guard let lowerBound = syncStartDate() else {
            logMessage("Historical workout-stats rescan refused: no finite syncDaysBack configured on this installation - refusing an unbounded historical scan.")
            progress.status = .refusedUnboundedWindow
            saveHistoricalStatsRescanProgress(progress)
            completion(progress)
            return
        }
        guard let endpoint = self.syncEndpoint, let credential = self.authCredential else {
            logMessage("Historical workout-stats rescan cannot start: not signed in")
            completion(progress)
            return
        }
        guard let generation = beginSyncRun() else {
            logMessage("Historical workout-stats rescan deferred: ordinary sync is in progress")
            completion(progress)
            return
        }

        progress.status = .running
        saveHistoricalStatsRescanProgress(progress)
        runHistoricalStatsRescanChunk(
            olderThan: progress.olderThanCursor, lowerBound: lowerBound, maxWorkouts: maxWorkouts,
            endpoint: endpoint, credential: credential, generation: generation, completion: completion
        )
    }

    /// Explicit reset so a `.completed` or `.refusedUnboundedWindow` run
    /// can be deliberately restarted from the very beginning. Never
    /// called automatically.
    public func resetHistoricalWorkoutStatsRescan() {
        saveHistoricalStatsRescanProgress(.notStartedValue)
    }

    /// Cooperative - takes effect once the in-flight chunk finishes,
    /// never mid-chunk, so a pause always lands on a clean checkpoint.
    public func pauseHistoricalWorkoutStatsRescan() {
        var progress = historicalWorkoutStatsRescanProgress()
        guard progress.status == .running else { return }
        progress.status = .paused
        saveHistoricalStatsRescanProgress(progress)
    }

    /// Distinct from pause: a cancelled rescan's cursor is preserved but
    /// will only ever resume via an explicit
    /// `startHistoricalWorkoutStatsRescan()` call.
    public func cancelHistoricalWorkoutStatsRescan() {
        var progress = historicalWorkoutStatsRescanProgress()
        guard progress.status == .running || progress.status == .paused else { return }
        progress.status = .cancelled
        saveHistoricalStatsRescanProgress(progress)
    }

    // MARK: - Chunked driver

    private static let statsRescanChunkLimit = 20

    private func runHistoricalStatsRescanChunk(
        olderThan: Date?, lowerBound: Date, maxWorkouts: Int,
        endpoint: URL, credential: String, generation: Int,
        completion: @escaping (HistoricalStatsRescanProgress) -> Void
    ) {
        // Re-read from disk on every chunk boundary - pause/cancel write
        // directly to disk, and this is the one moment between chunks
        // where that write must be observed.
        let current = historicalWorkoutStatsRescanProgress()
        if current.status != .running || isSyncCancelled(generation: generation) {
            finishSync(generation: generation)
            completion(historicalWorkoutStatsRescanProgress())
            return
        }
        if current.scannedCount >= maxWorkouts {
            var updated = current
            updated.status = .stoppedAtWorkoutLimit
            saveHistoricalStatsRescanProgress(updated)
            finishSync(generation: generation)
            completion(updated)
            return
        }

        fetchOneHistoricalWorkoutChunk(olderThan: olderThan, lowerBound: lowerBound) { [weak self] success, workouts, nextOlderThan, isDone in
            guard let self = self else { return }
            if !success {
                var updated = self.historicalWorkoutStatsRescanProgress()
                updated.status = .failedEnumerationQuery
                self.saveHistoricalStatsRescanProgress(updated)
                self.finishSync(generation: generation, outcome: .failedQuery)
                completion(updated)
                return
            }
            // Never process more of this chunk than the remaining budget allows.
            let remainingBudget = maxWorkouts - current.scannedCount
            let boundedWorkouts = Array(workouts.prefix(max(0, remainingBudget)))
            let hitLimitThisChunk = boundedWorkouts.count < workouts.count

            self.processHistoricalStatsRescanWorkouts(
                boundedWorkouts, index: 0,
                endpoint: endpoint, credential: credential, generation: generation
            ) {
                var updated = self.historicalWorkoutStatsRescanProgress()
                if hitLimitThisChunk || updated.scannedCount >= maxWorkouts {
                    // Cursor advances only past what was actually
                    // processed, so the unprocessed tail of this chunk
                    // is re-examined (not skipped) next invocation.
                    updated.olderThanCursor = boundedWorkouts.last?.endDate ?? updated.olderThanCursor
                    updated.status = .stoppedAtWorkoutLimit
                    self.saveHistoricalStatsRescanProgress(updated)
                    self.finishSync(generation: generation)
                    completion(updated)
                    return
                }
                updated.olderThanCursor = nextOlderThan
                if isDone {
                    updated.status = .completed
                    self.saveHistoricalStatsRescanProgress(updated)
                    self.finishSync(generation: generation)
                    completion(updated)
                    return
                }
                self.saveHistoricalStatsRescanProgress(updated)
                self.runHistoricalStatsRescanChunk(
                    olderThan: nextOlderThan, lowerBound: lowerBound, maxWorkouts: maxWorkouts,
                    endpoint: endpoint, credential: credential, generation: generation, completion: completion
                )
            }
        }
    }

    /// Every enumerated workout is simply resent - see this file's own
    /// top-of-file doc comment for why there is no per-workout
    /// outcome to classify here, unlike the route rescan.
    private func processHistoricalStatsRescanWorkouts(
        _ workouts: [HKWorkout], index: Int,
        endpoint: URL, credential: String, generation: Int, done: @escaping () -> Void
    ) {
        guard index < workouts.count, !isSyncCancelled(generation: generation) else {
            done()
            return
        }
        let workout = workouts[index]
        var current = historicalWorkoutStatsRescanProgress()
        current.scannedCount += 1
        saveHistoricalStatsRescanProgress(current)

        // No routesByWorkoutId - this rescan never touches route data;
        // HistoricalRouteRescan.swift owns that recovery independently.
        let payloadDict = buildCombinedPayload(samples: [workout])
        uploadCombinedPayload(
            payload: payloadDict, endpoint: endpoint, credential: credential, generation: generation
        ) { [weak self] success in
            guard let self = self else { return }
            var afterUpload = self.historicalWorkoutStatsRescanProgress()
            if success {
                afterUpload.resentCount += 1
            } else {
                afterUpload.resendFailedCount += 1
            }
            self.saveHistoricalStatsRescanProgress(afterUpload)
            self.processHistoricalStatsRescanWorkouts(
                workouts, index: index + 1,
                endpoint: endpoint, credential: credential, generation: generation, done: done
            )
        }
    }
}
