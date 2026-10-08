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
/// Deliberately reuses, unchanged, one of the two things that already
/// handle this correctly for a NEW workout:
///   - `buildCombinedPayload`/`uploadCombinedPayload` - the SAME resend
///     mechanism RouteRetry.swift already uses. The server's existing
///     natural-key resolution (`EventRecordRepository.get_by_source_and_window`,
///     via import_service.py's `_resolve_event_for_route`) attaches the
///     now-found route to the SAME EventRecord; `bulk_create`'s
///     `ON CONFLICT DO NOTHING` guarantees this can never create a
///     second EventRecord. No new server code, no new wire format. This
///     lookup is a pure identity match (DataSource + exact
///     start/end timestamps), with no staleness/age constraint at all -
///     confirmed directly against EventRecordRepository.get_by_source_and_window
///     - so a resend from months after the original sync resolves
///     exactly as safely as one from minutes after.
///
/// What is DELIBERATELY NOT reused unchanged: `fetchRoutePayload(for:)`
/// itself. WP #30 hardening (2026-10-08) found that function's shared
/// miss-handling (`recordPendingRouteRetryIfNeeded`) would silently fold
/// three genuinely different HealthKit outcomes - no route object,
/// query failure, and an authorization problem - into the SAME live-sync
/// retry queue, which exists for a short (24h-bounded) timing race on a
/// workout actively being synced right now. A historical workout's own
/// "miss" after the fact is never that race. This file now calls the
/// lower-level `fetchRoutePayloadOutcome(for:)` directly (see that
/// function's own doc comment for the three distinct outcomes) and
/// interprets each one itself - see `processHistoricalRescanWorkouts`
/// below.
///
/// What IS new here: enumerating historical `HKWorkout`s at all (ordinary
/// sync is anchor-based, forward-only, and never revisits an already-
/// synced workout) and doing it resumably, with pause/cancel, bounded to
/// exactly the window this installation has already imported AND to an
/// explicit, caller-supplied maximum workout count per invocation.
///
/// Scope boundary (WP #30 locked decision - "do not expand the historical
/// workout-import window without separate approval"): this rescans
/// EXACTLY the window `syncStartDate()` already defines for ordinary
/// sync on this device - never further back, and NEVER with no bound at
/// all. If `syncStartDate()` returns nil (this installation has no
/// finite `syncDaysBack` configured), `startHistoricalRouteRescan`
/// refuses to start - see its own doc comment. Resending a workout this
/// installation already uploaded is safe (idempotent, natural-key
/// resolved); resending one it never uploaded would be an unauthorized
/// expansion of what this installation imports, not a route recovery.
///
/// WP #30 targeted-rescan hardening (2026-10-09) - `startHistoricalRouteRescan`'s
/// optional `targetWindow` parameter can narrow this further, to an
/// explicit sub-range a caller already knows contains unresolved
/// workouts (so a small, targeted pilot invocation isn't spent
/// re-examining already-resolved recent history first) - but can only
/// ever narrow, never widen: the scope boundary above is unconditional
/// and structurally enforced regardless of what any caller passes. See
/// `HistoricalRescanTargetWindow` and `startHistoricalRouteRescan`'s own
/// doc comment for the full mechanism.
extension OpenWearablesHealthSDK {

    // MARK: - Progress model

    public enum HistoricalRescanStatus: String, Codable {
        case notStarted
        case running
        case paused
        case cancelled
        case completed
        /// WP #30 hardening - this installation has no finite
        /// `syncDaysBack` configured (`syncStartDate()` returned nil), so
        /// an unbounded historical scan was refused before touching
        /// HealthKit at all. Resolve by configuring a finite
        /// `syncDaysBack` first; there is no override.
        case refusedUnboundedWindow
        /// WP #30 hardening - stopped after reaching the caller-supplied
        /// `maxWorkouts` for this invocation, NOT because the window was
        /// exhausted. Distinct from `.paused`/`.cancelled`: this is an
        /// intentional, self-imposed stop, resumable the same way (call
        /// `startHistoricalRouteRescan` again; `olderThanCursor` picks up
        /// exactly where this invocation stopped).
        case stoppedAtWorkoutLimit
        /// WP #30 hardening - a HealthKit route query failed with
        /// `HKError.errorAuthorizationDenied`. The run halts immediately
        /// (not just this one workout) since every subsequent query in
        /// the same run would fail identically - continuing would burn
        /// through the whole chunk for no benefit. Never counted toward
        /// `noRouteConfirmedCount`: an authorization problem is never
        /// evidence that a route doesn't exist. Resolve by restoring
        /// HealthKit authorization, then call `startHistoricalRouteRescan`
        /// again - `olderThanCursor` is unchanged, nothing already found
        /// is lost.
        case failedAuthorization
        /// WP #30 hardening review (2026-10-09) - a REAL, verified gap
        /// this review found: the workout-ENUMERATION query itself
        /// (`fetchOneHistoricalWorkoutChunk`, distinct from a per-workout
        /// route query) failing previously left `status` stuck at
        /// `.running` forever - never set to any terminal value at all.
        /// This is not a data-safety bug (no Firestore/OW write ever
        /// happens on this path) but it IS a real status-reporting one:
        /// `pauseHistoricalRouteRescan()`/`cancelHistoricalRouteRescan()`
        /// both gate on `status == .running` and would have looked like
        /// they successfully paused/cancelled an attempt that was
        /// actually already dead. `olderThanCursor` is unchanged; retry
        /// by calling `startHistoricalRouteRescan` again.
        case failedEnumerationQuery
    }

    /// WP #30 targeted-rescan hardening (2026-10-09) - an explicit,
    /// caller-supplied sub-range within the device's existing
    /// `syncStartDate()` window. Exists so a pilot can target a small,
    /// specific, already-known slice of history (e.g. a handful of
    /// workouts confirmed missing a route) instead of always scanning
    /// newest-first from today, which can spend an entire invocation's
    /// `maxWorkouts` budget on already-resolved recent workouts before
    /// ever reaching an older, genuinely unresolved one - see
    /// `startHistoricalRouteRescan`'s own doc comment for the full
    /// mechanism and the structural guarantee that this can never widen
    /// the scan past the existing 30-day-style ceiling.
    ///
    /// `start`/`end` are validated by `startHistoricalRouteRescan`
    /// itself (`end` must be strictly after `start`) - this struct is a
    /// plain value type with no validation of its own, so constructing
    /// an invalid one is always possible but is always rejected, safely
    /// and visibly, at the one call site that matters.
    public struct HistoricalRescanTargetWindow: Codable, Equatable {
        public let start: Date
        public let end: Date
        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
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
        /// WP #30 hardening - a route query that succeeded (no error)
        /// and found zero HKWorkoutRoute objects for a workout old
        /// enough that "still arriving" is not a plausible explanation.
        /// This, and ONLY this, is what the rescan treats as a confirmed
        /// "no route ever existed" - never a query failure, never an
        /// authorization problem.
        public internal(set) var noRouteConfirmedCount: Int
        /// WP #30 hardening - a route query that returned a REAL
        /// HealthKit error (not merely zero results). Left for a later
        /// rescan invocation to re-examine; never counted as "no route,"
        /// never queued into the live-sync Stage F retry path (whose 24h
        /// window has no bearing on a months-old workout).
        public internal(set) var queryFailedCount: Int
        /// WP #30 targeted-rescan hardening (2026-10-09) - the window
        /// THIS run actually locked in, the first time it genuinely
        /// began (see `startHistoricalRouteRescan`'s own doc comment for
        /// exactly when that is). `nil` means "no window - the full
        /// `syncStartDate()` range," which is also a real, deliberately
        /// recorded decision, not an absence of one. Once a run has
        /// begun, every later call to `startHistoricalRouteRescan` - a
        /// resume after pause/cancel/stoppedAtWorkoutLimit/
        /// failedAuthorization/failedEnumerationQuery - reuses THIS
        /// value and ignores whatever `targetWindow` argument that call
        /// is given, even a different one or none at all. This is what
        /// makes "a resumed scan cannot escape its original target
        /// window" a stored fact, not a convention the caller has to
        /// uphold on its own.
        public internal(set) var targetWindow: HistoricalRescanTargetWindow?

        static let notStartedValue = HistoricalRescanProgress(
            status: .notStarted, olderThanCursor: nil, scannedCount: 0,
            routeFoundCount: 0, resentCount: 0, resendFailedCount: 0,
            noRouteConfirmedCount: 0, queryFailedCount: 0, targetWindow: nil
        )
    }

    // MARK: - Persisted state
    //
    // Test seams (historicalRescanEnumerationOverrideForTests,
    // routePayloadOutcomeOverrideForTests) are real stored properties
    // declared on the main class in OpenWearablesHealthSDK.swift —
    // mirroring routeRetryLookupOverrideForTests's own placement — not
    // here, since Swift extensions cannot declare stored properties.
    // routePayloadOutcomeOverrideForTests sits BELOW
    // fetchRoutePayloadOutcome (not at a historical-rescan-specific
    // wrapper) so a test still exercises this file's own real outcome-
    // interpretation logic in processHistoricalRescanWorkouts - see WP
    // #30's 2026-10-08 hardening pass.

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

    /// Default cap on how many workouts ONE invocation will scan, used
    /// when a caller doesn't supply its own. WP #30 hardening - the
    /// pilot plan calls for an explicit, much smaller cap than this
    /// (e.g. 25-50) per invocation; this default exists only so the
    /// parameter has a safe, non-infinite value, never as a recommendation.
    public static let defaultMaxWorkoutsPerHistoricalRescanInvocation = 200

    /// Starts a new rescan, or resumes one already in progress — the
    /// persisted `olderThanCursor` makes these the same operation.
    /// Interrupting the app (killed, backgrounded past its budget) and
    /// calling this again later picks up exactly where the last
    /// completed chunk left off; nothing is lost except the
    /// in-flight-but-uncompleted chunk, which is itself safe to redo
    /// (fetchRoutePayloadOutcome and the resend path are idempotent).
    ///
    /// WP #30 hardening (2026-10-08) - two bounds are now mandatory, not
    /// optional:
    ///   - This installation must have a FINITE sync window
    ///     (`syncStartDate()` non-nil, i.e. a real `syncDaysBack` is
    ///     configured). A missing/zero/unset value previously meant "no
    ///     lower bound at all" - silently rescanning this device's
    ///     ENTIRE HealthKit history. That is now refused outright,
    ///     before any HealthKit query runs - status becomes
    ///     `.refusedUnboundedWindow`. There is no override parameter;
    ///     fix the device's own `syncDaysBack` configuration first.
    ///   - `maxWorkouts` caps how many workouts THIS invocation will
    ///     scan, independent of the window size. Reaching it stops the
    ///     run cleanly (`.stoppedAtWorkoutLimit`, resumable exactly like
    ///     a pause) rather than continuing until the whole window is
    ///     exhausted.
    ///
    /// WP #30 targeted-rescan hardening (2026-10-09) - `targetWindow`
    /// (optional, default `nil`) narrows the scan to an explicit
    /// sub-range. Omitting it is byte-for-byte the prior behavior - the
    /// scan covers the whole `syncStartDate()` window exactly as before.
    /// When supplied:
    ///   - `targetWindow.end` must be strictly after `targetWindow.start`
    ///     - an invalid (empty or inverted) window is refused outright,
    ///     exactly like an invalid `maxWorkouts`: nothing changes, the
    ///     current progress is returned unmodified, and the scan is
    ///     NOT silently widened to the full window as a fallback.
    ///   - The effective lower bound is `max(targetWindow.start,
    ///     syncStartDate())` - a `targetWindow.start` earlier than the
    ///     device's own 30-day-style ceiling can never push the floor
    ///     earlier than that ceiling already allows. The
    ///     `.refusedUnboundedWindow` guard above still runs first and is
    ///     completely unaffected - a target window can never be used to
    ///     bypass it.
    ///   - **Once a run has genuinely begun** (progress.status is
    ///     anything other than `.notStarted` or `.refusedUnboundedWindow`
    ///     - i.e. at least one chunk has actually been attempted), the
    ///     window it locked in at that moment (`progress.targetWindow`,
    ///     possibly `nil` meaning "no window") is what every later call
    ///     uses - resuming after `.paused`/`.cancelled`/
    ///     `.stoppedAtWorkoutLimit`/`.failedAuthorization`/
    ///     `.failedEnumerationQuery` ALWAYS reuses that stored window and
    ///     ignores whatever `targetWindow` THIS call is given, even a
    ///     different one or none at all. A resumed scan cannot escape
    ///     its original target window - see
    ///     `testResumedScanReusesItsOriginalTargetWindowEvenWhenGivenADifferentOrNoWindow`.
    ///     `.notStarted` and `.refusedUnboundedWindow` are the only two
    ///     states where no run has actually begun yet, so the caller's
    ///     current argument is accepted and becomes the newly locked-in
    ///     window.
    public func startHistoricalRouteRescan(
        maxWorkouts: Int = defaultMaxWorkoutsPerHistoricalRescanInvocation,
        targetWindow: HistoricalRescanTargetWindow? = nil,
        completion: @escaping (HistoricalRescanProgress) -> Void
    ) {
        var progress = historicalRouteRescanProgress()
        if progress.status == .completed {
            completion(progress)
            return
        }
        guard maxWorkouts > 0 else {
            logMessage("Historical route rescan cannot start: maxWorkouts must be positive, got \(maxWorkouts)")
            completion(progress)
            return
        }
        if let targetWindow, targetWindow.end <= targetWindow.start {
            // WP #30 targeted-rescan hardening - fail safely, never
            // silently fall back to scanning the full window. Progress
            // is returned completely unmodified.
            logMessage("Historical route rescan cannot start: targetWindow.end must be after targetWindow.start.")
            completion(progress)
            return
        }
        guard let lowerBoundFromSyncWindow = syncStartDate() else {
            logMessage("Historical route rescan refused: no finite syncDaysBack configured on this installation - refusing an unbounded historical scan.")
            progress.status = .refusedUnboundedWindow
            saveHistoricalRescanProgress(progress)
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

        // WP #30 targeted-rescan hardening - a run that has already
        // begun locks in whatever window (including none) it started
        // with; only a genuinely fresh decision point accepts THIS
        // call's argument. See this function's own doc comment above.
        let runAlreadyBegan = progress.status != .notStarted && progress.status != .refusedUnboundedWindow
        let effectiveWindow = runAlreadyBegan ? progress.targetWindow : targetWindow

        let lowerBound = effectiveWindow.map { Swift.max($0.start, lowerBoundFromSyncWindow) } ?? lowerBoundFromSyncWindow
        // The window's upper edge only ever matters for the very first
        // query of a run that has no cursor yet - every later chunk
        // (same run or a resume) already has a cursor that can never
        // exceed it, since the cursor only ever derives from a
        // previously-bounded query's own oldest result.
        let initialOlderThan = progress.olderThanCursor ?? effectiveWindow?.end

        progress.status = .running
        progress.targetWindow = effectiveWindow
        saveHistoricalRescanProgress(progress)
        runHistoricalRescanChunk(
            olderThan: initialOlderThan, lowerBound: lowerBound, maxWorkouts: maxWorkouts,
            endpoint: endpoint, credential: credential, generation: generation, completion: completion
        )
    }

    /// WP #30 hardening - explicit reset so a `.completed`,
    /// `.refusedUnboundedWindow`, `.failedAuthorization`, or
    /// `.failedEnumerationQuery` run can be deliberately restarted from
    /// the very beginning (a fresh `olderThanCursor` of nil, all counts
    /// back to zero) rather than being permanently stuck, now that NONE
    /// of those terminal states auto-resumes. Never called
    /// automatically; an operator/pilot action.
    public func resetHistoricalRouteRescan() {
        saveHistoricalRescanProgress(.notStartedValue)
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
        olderThan: Date?, lowerBound: Date, maxWorkouts: Int,
        endpoint: URL, credential: String, generation: Int,
        completion: @escaping (HistoricalRescanProgress) -> Void
    ) {
        // Re-read from disk on every chunk boundary — pause/cancel write
        // directly to disk from whatever thread called them, and this is
        // the one moment between chunks where that write must be observed.
        let current = historicalRouteRescanProgress()
        if current.status != .running || isSyncCancelled(generation: generation) {
            finishSync(generation: generation)
            completion(historicalRouteRescanProgress())
            return
        }
        // WP #30 hardening - the workout-count cap is checked at the
        // chunk boundary too (not just inside processHistoricalRescanWorkouts),
        // so a resumed run that was already at/over the limit from a
        // prior invocation stops immediately rather than fetching one
        // more chunk it won't be allowed to process.
        if current.scannedCount >= maxWorkouts {
            var updated = current
            updated.status = .stoppedAtWorkoutLimit
            saveHistoricalRescanProgress(updated)
            finishSync(generation: generation)
            completion(updated)
            return
        }

        fetchOneHistoricalWorkoutChunk(olderThan: olderThan, lowerBound: lowerBound) { [weak self] success, workouts, nextOlderThan, isDone in
            guard let self = self else { return }
            if !success {
                // WP #30 hardening review (2026-10-09) - must land on a
                // real terminal status, never leave `.running` persisted
                // with nothing actually running (see
                // .failedEnumerationQuery's own doc comment for why that
                // was a real gap, not just an untested one).
                var updated = self.historicalRouteRescanProgress()
                updated.status = .failedEnumerationQuery
                self.saveHistoricalRescanProgress(updated)
                self.finishSync(generation: generation, outcome: .failedQuery)
                completion(updated)
                return
            }
            // Never process more of this chunk than the remaining budget
            // allows - a chunk of 20 workouts when only 5 remain under
            // maxWorkouts must stop at 5, not run the other 15 anyway.
            let remainingBudget = maxWorkouts - current.scannedCount
            let boundedWorkouts = Array(workouts.prefix(max(0, remainingBudget)))
            let hitLimitThisChunk = boundedWorkouts.count < workouts.count

            self.processHistoricalRescanWorkouts(
                boundedWorkouts, index: 0,
                endpoint: endpoint, credential: credential, generation: generation
            ) { haltedByAuthFailure in
                var updated = self.historicalRouteRescanProgress()
                if haltedByAuthFailure {
                    updated.status = .failedAuthorization
                    self.saveHistoricalRescanProgress(updated)
                    self.finishSync(generation: generation)
                    completion(updated)
                    return
                }
                if hitLimitThisChunk || updated.scannedCount >= maxWorkouts {
                    // Cursor still advances only past what was actually
                    // processed - boundedWorkouts.last, not workouts.last -
                    // so the unprocessed tail of this chunk is re-examined
                    // (not skipped) on the next invocation.
                    updated.olderThanCursor = boundedWorkouts.last?.endDate ?? updated.olderThanCursor
                    updated.status = .stoppedAtWorkoutLimit
                    self.saveHistoricalRescanProgress(updated)
                    self.finishSync(generation: generation)
                    completion(updated)
                    return
                }
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
                    olderThan: nextOlderThan, lowerBound: lowerBound, maxWorkouts: maxWorkouts,
                    endpoint: endpoint, credential: credential, generation: generation, completion: completion
                )
            }
        }
    }

    /// `done(haltedByAuthFailure:)` - `true` only when a route query
    /// failed with `HKError.errorAuthorizationDenied`, the one outcome
    /// that must stop the ENTIRE run rather than just advancing past one
    /// workout: every subsequent query in this run would fail the same
    /// way, and an authorization problem is never evidence that a route
    /// doesn't exist (must never be counted as `noRouteConfirmedCount`).
    private func processHistoricalRescanWorkouts(
        _ workouts: [HKWorkout], index: Int,
        endpoint: URL, credential: String, generation: Int, done: @escaping (_ haltedByAuthFailure: Bool) -> Void
    ) {
        guard index < workouts.count, !isSyncCancelled(generation: generation) else {
            done(false)
            return
        }
        let workout = workouts[index]
        fetchRoutePayloadOutcome(for: workout) { [weak self] outcome in
            guard let self = self else { return }
            var current = self.historicalRouteRescanProgress()
            current.scannedCount += 1

            switch outcome {
            case .queryFailed(isAuthorizationDenied: true):
                // Halt the whole run - do NOT advance to the next
                // workout, do NOT touch noRouteConfirmedCount/queryFailedCount.
                self.saveHistoricalRescanProgress(current)
                done(true)
                return

            case .queryFailed(isAuthorizationDenied: false):
                // A real HealthKit error, not merely zero results. Never
                // "no route," never queued into the live-sync Stage F
                // retry path - left for a LATER rescan invocation to
                // re-examine.
                current.queryFailedCount += 1
                self.saveHistoricalRescanProgress(current)
                self.processHistoricalRescanWorkouts(
                    workouts, index: index + 1,
                    endpoint: endpoint, credential: credential, generation: generation, done: done
                )

            case .noRouteObjectsPresent:
                // The query succeeded with zero objects for a workout old
                // enough that "still arriving" (Stage F's own reasoning)
                // does not apply - this IS the confirmed "no route" case.
                current.noRouteConfirmedCount += 1
                self.saveHistoricalRescanProgress(current)
                self.processHistoricalRescanWorkouts(
                    workouts, index: index + 1,
                    endpoint: endpoint, credential: credential, generation: generation, done: done
                )

            case .found(let payload):
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
