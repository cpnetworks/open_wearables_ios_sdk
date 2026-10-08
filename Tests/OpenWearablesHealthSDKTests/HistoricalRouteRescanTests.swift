import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Sole Mates WP #30 (2026-10-08) - Historical GPS Route Recovery.
///
/// Same testing discipline as RouteRetryTests: nothing here touches a
/// real HealthKit store. `historicalRescanEnumerationOverrideForTests`
/// stands in for the one piece that genuinely requires HealthKit
/// (enumerating historical HKWorkouts); `routePayloadOutcomeOverrideForTests`
/// stands in for the lower-level `fetchRoutePayloadOutcome` - placed
/// BELOW `processHistoricalRescanWorkouts`'s own outcome-interpretation
/// logic (unlike the old, now-removed `historicalRescanRouteLookupOverrideForTests`,
/// which bypassed that logic entirely), so the WP #30 2026-10-08
/// hardening pass's actual decision-making (noRouteConfirmedCount vs.
/// queryFailedCount vs. halting on authorization denial) runs for real
/// in every test below - only the raw HealthKit call is faked.
final class HistoricalRouteRescanTests: XCTestCase {

    private func fakeWorkout(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> HKWorkout {
        HKWorkout(
            activityType: .running, start: start, end: start.addingTimeInterval(1800),
            workoutEvents: nil, totalEnergyBurned: nil, totalDistance: nil, metadata: nil
        )
    }

    private let fakeRoutePoints: [[String: Any]] = [
        ["t": "2026-01-15T08:00:00Z", "lat": 1.0, "lng": 1.0],
        ["t": "2026-01-15T08:00:01Z", "lat": 1.0001, "lng": 1.0001],
    ]

    // MARK: - Not signed in

    func testCannotStartWhenNotSignedIn() {
        withIsolatedSDK(accessToken: nil, refreshToken: nil) { sdk, _ in
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not query HealthKit when not signed in")
                completion(false, [], nil, false)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .notStarted)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Enumeration query failure (WP #30 hardening review, 2026-10-09)

    /// A REAL gap this review found (not merely untested): the
    /// enumeration query (distinct from a per-workout route query)
    /// failing previously left `status` stuck at `.running` forever -
    /// never any terminal value - which would have made
    /// `pauseHistoricalRouteRescan`/`cancelHistoricalRouteRescan` look
    /// like they succeeded against an attempt that was already dead.
    func testEnumerationQueryFailureLandsOnATerminalStatusNotStuckRunning() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(false, [], nil, false)  // the query itself failed
            }
            let firstExpectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .failedEnumerationQuery, "must land on a real terminal status, never remain .running with nothing actually running")
                firstExpectation.fulfill()
            }
            wait(for: [firstExpectation], timeout: 2)

            XCTAssertEqual(sdk.historicalRouteRescanProgress().status, .failedEnumerationQuery, "the persisted status must match too, not just the completion callback's argument")

            // pause/cancel must not be fooled into thinking something
            // live is still running.
            sdk.pauseHistoricalRouteRescan()
            XCTAssertEqual(sdk.historicalRouteRescanProgress().status, .failedEnumerationQuery, "pause must be a no-op against a non-running status")

            // Retrying (not resetting) must be possible and must reach
            // HealthKit again.
            var retried = false
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                retried = true
                completion(true, [], nil, true)
            }
            let retryExpectation = expectation(description: "retry completes")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                retryExpectation.fulfill()
            }
            wait(for: [retryExpectation], timeout: 2)
            XCTAssertTrue(retried)
        }
    }

    // MARK: - Bounded-scan enforcement (WP #30 hardening)

    func testRefusesToStartWithNoFiniteSyncWindow() {
        withIsolatedSDK { sdk, _ in
            // `withIsolatedSDK` does not reset syncDaysBack between tests
            // (it is not part of that helper's save/restore list), so an
            // earlier test in the same run saving a real value would
            // otherwise leak into this one — reset explicitly rather than
            // relying on being the first test to touch it.
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(0)
            XCTAssertNil(sdk.syncStartDate(), "precondition: no finite sync window configured")

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not query HealthKit at all when the sync window is unbounded")
                completion(false, [], nil, false)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .refusedUnboundedWindow)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    func testRefusesNonPositiveMaxWorkouts() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not query HealthKit when maxWorkouts is invalid")
                completion(false, [], nil, false)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(maxWorkouts: 0) { progress in
                XCTAssertEqual(progress.status, .notStarted)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    func testStopsAtTheWorkoutLimitAndCanResume() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workouts = (0..<5).map { fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 100_000)) }
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, workouts, nil, true) // one chunk, "isDone" per HealthKit, but limit cuts it short
                } else {
                    XCTFail("must not fetch another chunk within the same bounded invocation")
                    completion(true, [], nil, true)
                }
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in completion(.noRouteObjectsPresent) }

            let firstExpectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(maxWorkouts: 3) { progress in
                XCTAssertEqual(progress.status, .stoppedAtWorkoutLimit)
                XCTAssertEqual(progress.scannedCount, 3, "must stop exactly at the cap, not process all 5")
                firstExpectation.fulfill()
            }
            wait(for: [firstExpectation], timeout: 2)

            // Resume: a second invocation with a fresh, larger budget
            // must pick up from the cursor, not restart from the beginning.
            var secondRunOlderThan: Date? = Date() // sentinel
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                secondRunOlderThan = olderThan
                completion(true, [], nil, true)
            }
            let secondExpectation = expectation(description: "second run completion called")
            sdk.startHistoricalRouteRescan(maxWorkouts: 100) { progress in
                XCTAssertEqual(progress.status, .completed)
                secondExpectation.fulfill()
            }
            wait(for: [secondExpectation], timeout: 2)
            XCTAssertEqual(secondRunOlderThan, workouts[2].endDate, "must resume from the 3rd (last processed) workout's own cursor")
        }
    }

    // MARK: - Fresh start

    func testFreshStartQueriesWithNilOlderThanCursor() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            var capturedOlderThan: Date? = Date()  // sentinel, overwritten below
            var capturedAnyCall = false
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                capturedAnyCall = true
                capturedOlderThan = olderThan
                completion(true, [], nil, true)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { _ in expectation.fulfill() }
            wait(for: [expectation], timeout: 2)

            XCTAssertTrue(capturedAnyCall)
            XCTAssertNil(capturedOlderThan)
        }
    }

    func testEmptyFirstChunkMarksCompleted() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [], nil, true)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Scope boundary

    func testNeverQueriesEarlierThanSyncStartDate() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let expectedLowerBound = sdk.syncStartDate()
            XCTAssertNotNil(expectedLowerBound, "precondition: syncDaysBack must actually bound syncStartDate()")

            var capturedLowerBound: Date?? = .some(Date())
            sdk.historicalRescanEnumerationOverrideForTests = { _, lowerBound, _, completion in
                capturedLowerBound = lowerBound
                completion(true, [], nil, true)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { _ in expectation.fulfill() }
            wait(for: [expectation], timeout: 2)

            XCTAssertEqual(capturedLowerBound, expectedLowerBound, "must rescan exactly the same window ordinary sync uses, never further back")
        }
    }

    // MARK: - Target window (WP #30 targeted-rescan hardening, 2026-10-09)

    private let oneDay: TimeInterval = 86_400

    func testTargetWindowOmittedPreservesExactPriorBehavior() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let expectedLowerBound = sdk.syncStartDate()
            var capturedOlderThan: Date? = Date()  // sentinel, overwritten below
            var capturedLowerBound: Date?? = .some(Date())
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, lowerBound, _, completion in
                capturedOlderThan = olderThan
                capturedLowerBound = lowerBound
                completion(true, [], nil, true)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { _ in expectation.fulfill() }
            wait(for: [expectation], timeout: 2)

            XCTAssertNil(capturedOlderThan, "no targetWindow means no upper bound, exactly as before this change")
            XCTAssertEqual(capturedLowerBound, expectedLowerBound, "no targetWindow means the full syncStartDate() window, exactly as before this change")
        }
    }

    func testTargetWindowRestrictsEnumerationToTheExplicitSubRange() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(30)
            let ceiling = sdk.syncStartDate()!
            // Comfortably inside the 30-day ceiling, so the window's own
            // bounds - not the ceiling - are what should be observed.
            let windowStart = ceiling.addingTimeInterval(10 * oneDay)
            let windowEnd = ceiling.addingTimeInterval(20 * oneDay)

            var capturedOlderThan: Date?? = .some(Date())
            var capturedLowerBound: Date?? = .some(Date())
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, lowerBound, _, completion in
                capturedOlderThan = olderThan
                capturedLowerBound = lowerBound
                completion(true, [], nil, true)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(targetWindow: .init(start: windowStart, end: windowEnd)) { _ in expectation.fulfill() }
            wait(for: [expectation], timeout: 2)

            XCTAssertEqual(capturedLowerBound, windowStart, "the window's own start, not the full 30-day ceiling, must be the effective lower bound")
            XCTAssertEqual(capturedOlderThan, windowEnd, "the window's own end must bound the first query's upper edge")
        }
    }

    func testTargetWindowLowerBoundNeverEarlierThanThe30DayCeiling() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(5)
            let ceiling = sdk.syncStartDate()!
            // The window's own start is BEFORE the 5-day ceiling - a
            // misconfigured or malicious caller trying to reach further
            // back than the device's own syncDaysBack allows.
            let earlierThanCeiling = ceiling.addingTimeInterval(-25 * oneDay)
            let windowEnd = ceiling.addingTimeInterval(1 * oneDay)

            var capturedLowerBound: Date?? = .some(Date())
            sdk.historicalRescanEnumerationOverrideForTests = { _, lowerBound, _, completion in
                capturedLowerBound = lowerBound
                completion(true, [], nil, true)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(targetWindow: .init(start: earlierThanCeiling, end: windowEnd)) { _ in expectation.fulfill() }
            wait(for: [expectation], timeout: 2)

            XCTAssertEqual(capturedLowerBound, ceiling, "the effective lower bound must be clamped to the 30-day-style ceiling, never honoring a window.start earlier than it")
        }
    }

    func testTargetWindowRefusesInvalidOrdering() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not touch HealthKit at all with an invalid (empty/inverted) target window")
                completion(false, [], nil, false)
            }
            let same = Date()
            let expectation = expectation(description: "completion called")
            // end == start is empty; end < start is inverted - both invalid.
            sdk.startHistoricalRouteRescan(targetWindow: .init(start: same, end: same)) { progress in
                XCTAssertEqual(progress.status, .notStarted, "must refuse cleanly, never silently fall back to the full window")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
            XCTAssertNil(sdk.historicalRouteRescanProgress().targetWindow, "an invalid window must never be persisted")
        }
    }

    func testTargetWindowSmallerThanOneChunkCompletesWithoutScanningPastIt() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(30)
            let ceiling = sdk.syncStartDate()!
            let windowStart = ceiling.addingTimeInterval(10 * oneDay)
            let windowEnd = ceiling.addingTimeInterval(11 * oneDay)
            // Exactly the pilot's own real shape: a handful of known
            // workouts, well under both the chunk limit (20) and
            // maxWorkouts (25).
            let workouts = (0..<4).map { fakeWorkout(start: windowStart.addingTimeInterval(Double($0) * 60)) }

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, workouts, nil, true) // the window is exhausted - isDone per HealthKit's own signal
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in completion(.noRouteObjectsPresent) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(maxWorkouts: 25, targetWindow: .init(start: windowStart, end: windowEnd)) { progress in
                XCTAssertEqual(progress.status, .completed, "a window exhausted well under budget must complete, not report a workout-limit stop")
                XCTAssertEqual(progress.scannedCount, 4, "exactly the known workouts in the window, not padded out toward the 25 cap")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    func testTargetWindowProcessesAllWorkoutsInOneChunkInTheGivenOrder() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(30)
            let ceiling = sdk.syncStartDate()!
            let windowStart = ceiling.addingTimeInterval(10 * oneDay)
            let windowEnd = ceiling.addingTimeInterval(11 * oneDay)
            let workouts = (0..<3).map { fakeWorkout(start: windowStart.addingTimeInterval(Double($0) * 60)) }

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, workouts, nil, true)
            }
            var processedOrder: [Date] = []
            sdk.routePayloadOutcomeOverrideForTests = { workout, completion in
                processedOrder.append(workout.startDate)
                completion(.noRouteObjectsPresent)
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(targetWindow: .init(start: windowStart, end: windowEnd)) { progress in
                XCTAssertEqual(progress.scannedCount, 3, "every workout in the window's single chunk must be processed")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertEqual(processedOrder, workouts.map(\.startDate), "must process them in exactly the order HealthKit returned them, unmodified by narrowing the window")
        }
    }

    func testTargetWindowCancellationPreservesCursorWithinTheWindow() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(30)
            let ceiling = sdk.syncStartDate()!
            let windowStart = ceiling.addingTimeInterval(10 * oneDay)
            let windowEnd = ceiling.addingTimeInterval(11 * oneDay)
            let workout = fakeWorkout(start: windowStart.addingTimeInterval(60))

            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == windowEnd {
                    completion(true, [workout], workout.endDate, false)
                } else {
                    XCTFail("must not start a second chunk after cancellation")
                    completion(true, [], nil, true)
                }
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                sdk.cancelHistoricalRouteRescan()
                completion(.noRouteObjectsPresent)
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan(targetWindow: .init(start: windowStart, end: windowEnd)) { progress in
                XCTAssertEqual(progress.status, .cancelled)
                XCTAssertEqual(progress.olderThanCursor, workout.endDate, "cursor must still advance correctly to exactly what was processed, same as without a window")
                XCTAssertEqual(progress.targetWindow, .init(start: windowStart, end: windowEnd), "the window itself must still be the one persisted")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    /// WP #30 targeted-rescan hardening (2026-10-09) - the specific,
    /// required regression test: once a run has genuinely begun, no
    /// LATER call can widen or move its window, whether that call
    /// supplies a completely different window or omits the argument
    /// entirely. Exercises both sub-cases in one run, matching exactly
    /// what was asked for.
    func testResumedScanReusesItsOriginalTargetWindowEvenWhenGivenADifferentOrNoWindow() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(30)
            let ceiling = sdk.syncStartDate()!
            let originalWindow = OpenWearablesHealthSDK.HistoricalRescanTargetWindow(
                start: ceiling.addingTimeInterval(10 * oneDay),
                end: ceiling.addingTimeInterval(11 * oneDay)
            )
            let decoyWindow = OpenWearablesHealthSDK.HistoricalRescanTargetWindow(
                start: ceiling.addingTimeInterval(20 * oneDay),
                end: ceiling.addingTimeInterval(21 * oneDay)
            )
            let firstWorkout = fakeWorkout(start: originalWindow.start.addingTimeInterval(60))

            // Run 1: starts fresh with the ORIGINAL window, pauses after
            // one workout (a non-final chunk, so a second chunk would
            // follow if not paused).
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, lowerBound, _, completion in
                XCTAssertEqual(olderThan, originalWindow.end)
                XCTAssertEqual(lowerBound, originalWindow.start)
                completion(true, [firstWorkout], firstWorkout.endDate, false)
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                sdk.pauseHistoricalRouteRescan()
                completion(.noRouteObjectsPresent)
            }
            let firstRun = expectation(description: "first run paused with the original window")
            sdk.startHistoricalRouteRescan(targetWindow: originalWindow) { progress in
                XCTAssertEqual(progress.status, .paused)
                firstRun.fulfill()
            }
            wait(for: [firstRun], timeout: 2)
            XCTAssertEqual(sdk.historicalRouteRescanProgress().targetWindow, originalWindow)

            // Run 2 (resume): supplies a COMPLETELY DIFFERENT window.
            // The decoy window must be entirely ignored - the lower
            // bound captured below must still be the ORIGINAL window's
            // start, never the decoy's.
            var secondRunCapturedLowerBound: Date?
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, lowerBound, _, completion in
                secondRunCapturedLowerBound = lowerBound
                XCTAssertEqual(olderThan, firstWorkout.endDate, "resume must use the persisted cursor, not either window's end")
                completion(true, [], nil, true)
            }
            let secondRun = expectation(description: "resumed with a different window argument")
            sdk.startHistoricalRouteRescan(targetWindow: decoyWindow) { progress in
                XCTAssertEqual(progress.status, .completed)
                secondRun.fulfill()
            }
            wait(for: [secondRun], timeout: 2)
            XCTAssertEqual(secondRunCapturedLowerBound, originalWindow.start, "a different window argument on resume must be completely ignored")
            XCTAssertEqual(sdk.historicalRouteRescanProgress().targetWindow, originalWindow, "the persisted window must remain the original one, not the decoy")

            // Run 3: reset and redo runs 1-2, but this time the resume
            // call OMITS targetWindow entirely (nil) rather than
            // supplying a decoy - must behave identically: the original
            // window still wins.
            sdk.resetHistoricalRouteRescan()
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [firstWorkout], firstWorkout.endDate, false)
            }
            let thirdRunStart = expectation(description: "third run paused with the original window")
            sdk.startHistoricalRouteRescan(targetWindow: originalWindow) { progress in
                XCTAssertEqual(progress.status, .paused)
                thirdRunStart.fulfill()
            }
            wait(for: [thirdRunStart], timeout: 2)

            var thirdRunCapturedLowerBound: Date?
            sdk.historicalRescanEnumerationOverrideForTests = { _, lowerBound, _, completion in
                thirdRunCapturedLowerBound = lowerBound
                completion(true, [], nil, true)
            }
            let thirdRunResume = expectation(description: "resumed with NO window argument")
            sdk.startHistoricalRouteRescan(targetWindow: nil) { progress in
                XCTAssertEqual(progress.status, .completed)
                thirdRunResume.fulfill()
            }
            wait(for: [thirdRunResume], timeout: 2)
            XCTAssertEqual(thirdRunCapturedLowerBound, originalWindow.start, "omitting targetWindow on resume must NOT widen the scan back to the full syncStartDate() window")
        }
    }

    // MARK: - Route found -> resend

    func testRouteFoundResendsThroughTheNormalSyncPayloadShape() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [workout], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { [weak self] _, completion in
                completion(.found(self?.fakeRoutePoints ?? []))
            }
            StubURLProtocol.install { _ in .status(202) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                XCTAssertEqual(progress.scannedCount, 1)
                XCTAssertEqual(progress.routeFoundCount, 1)
                XCTAssertEqual(progress.resentCount, 1)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertTrue(waitUntil { StubURLProtocol.requests(matching: "/sync").count == 1 })
            let resend = StubURLProtocol.recorded(matching: "/sync").first
            let workouts = (resend?.json?["data"] as? [String: Any])?["workouts"] as? [[String: Any]]
            XCTAssertEqual(workouts?.count, 1, "resends exactly the one workout, through the normal sync payload shape")
            XCTAssertNotNil(workouts?.first?["route"], "the recovered route must be attached to the resend")
        }
    }

    // MARK: - WP #30 hardening: the three outcomes, exercised through the REAL decision logic

    func testGenuinelyNoRouteIsCountedAsConfirmedNotPresent() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [workout], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                completion(.noRouteObjectsPresent)  // genuinely no route upstream — must not be fabricated
            }
            StubURLProtocol.install { _ in
                XCTFail("must not make any network call when no route was found")
                return .status(500)
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.scannedCount, 1)
                XCTAssertEqual(progress.routeFoundCount, 0)
                XCTAssertEqual(progress.resentCount, 0)
                XCTAssertEqual(progress.noRouteConfirmedCount, 1, "a genuine miss must be counted as confirmed, not silently dropped")
                XCTAssertEqual(progress.queryFailedCount, 0)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertTrue(sdk.loadPendingRouteRetries().isEmpty, "a historical confirmed-absent result must NEVER enter the live-sync Stage F retry queue")
        }
    }

    func testTransientQueryFailureIsNeverClassifiedAsNoRouteOrQueuedForLiveRetry() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let failing = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000))
            let fine = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_100_000))
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [failing, fine], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { workout, completion in
                if workout.startDate == failing.startDate {
                    completion(.queryFailed(isAuthorizationDenied: false))
                } else {
                    completion(.noRouteObjectsPresent)
                }
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed, "a non-authorization query failure must not halt the run")
                XCTAssertEqual(progress.scannedCount, 2, "the OTHER workout in the same chunk must still be processed")
                XCTAssertEqual(progress.queryFailedCount, 1)
                XCTAssertEqual(progress.noRouteConfirmedCount, 1, "must be exactly the genuinely-absent one, never the failed one")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertTrue(sdk.loadPendingRouteRetries().isEmpty, "a query failure must NEVER enter the live-sync Stage F retry queue either - that 24h window has no bearing on a historical rescan")
        }
    }

    func testAuthorizationDeniedHaltsTheEntireRunWithoutCountingAsNoRoute() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let first = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000))
            let second = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_100_000))
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [first, second], nil, true)
            }
            var secondWorkoutQueried = false
            sdk.routePayloadOutcomeOverrideForTests = { workout, completion in
                if workout.startDate == first.startDate {
                    completion(.queryFailed(isAuthorizationDenied: true))
                } else {
                    secondWorkoutQueried = true
                    completion(.noRouteObjectsPresent)
                }
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .failedAuthorization)
                XCTAssertEqual(progress.scannedCount, 1, "must halt immediately, never advance past the authorization failure")
                XCTAssertEqual(progress.noRouteConfirmedCount, 0, "an authorization problem must NEVER be counted as a confirmed no-route result")
                XCTAssertEqual(progress.queryFailedCount, 0, "distinct from a generic query failure - this is its own status")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertFalse(secondWorkoutQueried, "every subsequent workout in the same run must be skipped once authorization fails")
        }
    }

    /// WP #30 hardening review (2026-10-09) - the companion to the test
    /// above, specifically covering TWO things that test alone did not:
    /// (1) a workout that succeeded BEFORE the authorization failure in
    /// the SAME chunk, and (2) an actual resume call after the halt
    /// (the prior version of this test only set up a guard for this and
    /// never triggered it - a real gap, not just an untested one).
    func testCursorAfterAuthorizationHaltAndActualResumeBehavior() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let succeeds = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000))
            let fails = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_100_000))
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [succeeds, fails], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { [weak self] workout, completion in
                if workout.startDate == succeeds.startDate {
                    completion(.found(self?.fakeRoutePoints ?? []))
                } else {
                    completion(.queryFailed(isAuthorizationDenied: true))
                }
            }
            StubURLProtocol.install { _ in .status(202) }

            let halt = expectation(description: "halts on the second workout")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .failedAuthorization)
                XCTAssertEqual(progress.scannedCount, 2, "the first workout WAS scanned before the halt")
                XCTAssertEqual(progress.resentCount, 1, "its successful resend is NOT undone by the later halt")
                halt.fulfill()
            }
            wait(for: [halt], timeout: 2)

            // The core cursor question this review asked about: the
            // chunk's own nextOlderThan (nil, since isDone would have
            // been true) is NEVER persisted on a halt - the cursor stays
            // at whatever it was BEFORE this chunk started (nil, for a
            // fresh run), not advanced just because part of the chunk
            // was processed.
            XCTAssertNil(sdk.historicalRouteRescanProgress().olderThanCursor, "a halted chunk must never advance the cursor, even partially")

            // Known, accepted limitation (documented, not silently
            // assumed): resuming re-enumerates the SAME chunk via the
            // unchanged cursor, so the already-succeeded workout is
            // seen again. This is SAFE (idempotent resend, proven
            // elsewhere in this file) but the in-memory progress
            // COUNTERS are not reset across a halt+resume, so they
            // reflect cumulative attempts, not distinct workouts -
            // proven here rather than assumed.
            var reEnumeratedWithSameCursor = false
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                reEnumeratedWithSameCursor = (olderThan == nil)
                completion(true, [succeeds, fails], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { [weak self] workout, completion in
                // The underlying problem is now fixed on both workouts.
                if workout.startDate == succeeds.startDate {
                    completion(.found(self?.fakeRoutePoints ?? []))
                } else {
                    completion(.noRouteObjectsPresent)
                }
            }

            let resume = expectation(description: "resumes and completes")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                XCTAssertEqual(progress.scannedCount, 4, "cumulative across the halt+resume: 2 from the halted attempt + 2 from this one - a known counter-accounting limitation, not a production-safety one")
                XCTAssertEqual(progress.resentCount, 2, "the already-succeeded workout is safely (idempotently) resent again, not skipped")
                resume.fulfill()
            }
            wait(for: [resume], timeout: 2)
            XCTAssertTrue(reEnumeratedWithSameCursor, "resume must re-enumerate from the SAME (unchanged) cursor the halt left behind")
        }
    }

    // MARK: - Reset (WP #30 hardening)

    func testResetAllowsARestartAfterAFailedAuthorizationHalt() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [workout], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                completion(.queryFailed(isAuthorizationDenied: true))
            }
            let first = expectation(description: "first halts on authorization")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .failedAuthorization)
                first.fulfill()
            }
            wait(for: [first], timeout: 2)

            sdk.resetHistoricalRouteRescan()
            XCTAssertEqual(sdk.historicalRouteRescanProgress().status, .notStarted)
            XCTAssertNil(sdk.historicalRouteRescanProgress().olderThanCursor)
            XCTAssertEqual(sdk.historicalRouteRescanProgress().queryFailedCount, 0)

            sdk.routePayloadOutcomeOverrideForTests = { _, completion in completion(.noRouteObjectsPresent) }
            var reQueriedFromScratch = false
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                reQueriedFromScratch = (olderThan == nil)
                completion(true, [], nil, true)
            }
            let second = expectation(description: "second run after reset")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                second.fulfill()
            }
            wait(for: [second], timeout: 2)
            XCTAssertTrue(reQueriedFromScratch, "a reset run must start from nil, not the stale cursor")
        }
    }

    // MARK: - Multiple workouts in one chunk

    func testMultipleWorkoutsInOneChunkAreAllProcessed() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workouts = [
                fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000)),
                fakeWorkout(start: Date(timeIntervalSince1970: 1_700_100_000)),
                fakeWorkout(start: Date(timeIntervalSince1970: 1_700_200_000)),
            ]
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, workouts, nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { [weak self] workout, completion in
                // Only the middle one has a route — exercises the mixed case.
                if workout.startDate == workouts[1].startDate {
                    completion(.found(self?.fakeRoutePoints ?? []))
                } else {
                    completion(.noRouteObjectsPresent)
                }
            }
            StubURLProtocol.install { _ in .status(202) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.scannedCount, 3)
                XCTAssertEqual(progress.routeFoundCount, 1)
                XCTAssertEqual(progress.resentCount, 1)
                XCTAssertEqual(progress.noRouteConfirmedCount, 2)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Pause between chunks, not mid-chunk

    func testPauseRequestedDuringAChunkStillLetsThatChunkFinish() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let firstChunkWorkout = fakeWorkout()
            var secondChunkRequested = false

            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, [firstChunkWorkout], firstChunkWorkout.endDate, false)
                } else {
                    secondChunkRequested = true
                    completion(true, [], nil, true)
                }
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                sdk.pauseHistoricalRouteRescan()  // requested mid-first-chunk
                completion(.noRouteObjectsPresent)
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.scannedCount, 1, "the in-flight chunk still finished")
                XCTAssertEqual(progress.status, .paused)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertFalse(secondChunkRequested, "pause must take effect before the NEXT chunk starts")
        }
    }

    // MARK: - Cancel preserves cursor

    func testCancelPreservesCursorForAPossibleLaterResume() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, [workout], workout.endDate, false)
                } else {
                    XCTFail("must not start a second chunk after cancellation")
                    completion(true, [], nil, true)
                }
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                sdk.cancelHistoricalRouteRescan()
                completion(.noRouteObjectsPresent)
            }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .cancelled)
                XCTAssertEqual(progress.olderThanCursor, workout.endDate)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Resume from a persisted cursor

    func testResumeContinuesFromThePersistedCursorNotFromTheStart() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let firstWorkout = fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000))

            // Everything in this override chain resolves synchronously (no
            // real network/HealthKit async boundary when no route is
            // found), so pause must be requested FROM WITHIN the mid-flow
            // callback, not after startHistoricalRouteRescan returns —
            // by then the whole (synchronous) run would already be done.
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, [firstWorkout], firstWorkout.endDate, false)
                } else {
                    XCTFail("must not start a second chunk in the same run once paused")
                    completion(true, [], nil, true)
                }
            }
            sdk.routePayloadOutcomeOverrideForTests = { _, completion in
                sdk.pauseHistoricalRouteRescan()
                completion(.noRouteObjectsPresent)
            }

            let firstRun = expectation(description: "first run paused")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .paused)
                firstRun.fulfill()
            }
            wait(for: [firstRun], timeout: 2)
            XCTAssertEqual(sdk.historicalRouteRescanProgress().olderThanCursor, firstWorkout.endDate)

            var resumedWithCursor: Date??
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                resumedWithCursor = olderThan
                completion(true, [], nil, true)
            }
            let secondRun = expectation(description: "second run resumed")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                secondRun.fulfill()
            }
            wait(for: [secondRun], timeout: 2)

            XCTAssertEqual(resumedWithCursor, firstWorkout.endDate)
        }
    }

    // MARK: - Completed is a no-op on restart

    func testStartingAnAlreadyCompletedRescanIsANoOp() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [], nil, true)
            }
            let first = expectation(description: "first completes")
            sdk.startHistoricalRouteRescan { _ in first.fulfill() }
            wait(for: [first], timeout: 2)

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("a completed rescan must not query HealthKit again")
                completion(true, [], nil, true)
            }
            let second = expectation(description: "second returns immediately")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                second.fulfill()
            }
            wait(for: [second], timeout: 2)
        }
    }

    // MARK: - Interaction with normal foreground sync (WP #30 hardening)

    func testDefersRatherThanStartingWhileOrdinarySyncIsAlreadyRunning() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not touch HealthKit at all once deferred")
                completion(false, [], nil, false)
            }

            // Simulate an ordinary live sync already holding the shared
            // mutual-exclusion slot both features use.
            guard let liveSyncGeneration = sdk.beginSyncRun() else {
                XCTFail("precondition: must be able to claim the slot first")
                return
            }

            let deferredExpectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .notStarted, "must defer cleanly, not crash or corrupt state, while live sync holds the slot")
                deferredExpectation.fulfill()
            }
            wait(for: [deferredExpectation], timeout: 2)

            // The live sync's own slot must be completely unaffected by
            // the deferred historical-rescan attempt.
            XCTAssertFalse(sdk.isSyncCancelled(generation: liveSyncGeneration))
            sdk.finishSync(generation: liveSyncGeneration)

            // Once the live sync releases the slot, the rescan can start normally.
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [], nil, true)
            }
            let afterExpectation = expectation(description: "completion called after slot freed")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                afterExpectation.fulfill()
            }
            wait(for: [afterExpectation], timeout: 2)
        }
    }

    // MARK: - Identity/enrichment: no duplicate-creation risk (WP #30 hardening)

    func testHistoricalResendUsesTheIdenticalWorkoutIdentityAsOrdinarySync() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workout = fakeWorkout()

            // The ordinary-sync payload shape for this exact workout,
            // built the SAME way syncAll's own workout branch would.
            let ordinarySyncPayload = sdk.buildCombinedPayload(samples: [workout], routesByWorkoutId: [:])
            let ordinaryWorkouts = (ordinarySyncPayload["data"] as? [String: Any])?["workouts"] as? [[String: Any]]
            let ordinaryId = ordinaryWorkouts?.first?["id"] as? String

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [workout], nil, true)
            }
            sdk.routePayloadOutcomeOverrideForTests = { [weak self] _, completion in
                completion(.found(self?.fakeRoutePoints ?? []))
            }
            StubURLProtocol.install { _ in .status(202) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { _ in expectation.fulfill() }
            wait(for: [expectation], timeout: 2)

            let resend = StubURLProtocol.recorded(matching: "/sync").first
            let resentWorkouts = (resend?.json?["data"] as? [String: Any])?["workouts"] as? [[String: Any]]
            let resentId = resentWorkouts?.first?["id"] as? String

            XCTAssertNotNil(ordinaryId)
            XCTAssertEqual(resentId, ordinaryId, "the historical rescan's resend must use the EXACT SAME workout identity (HealthKit UUID) ordinary sync would - this, plus the server's time-independent natural-key lookup, is what rules out creating a duplicate EventRecord")
            XCTAssertEqual(resentId, workout.uuid.uuidString, "that identity must be HealthKit's own unchanged UUID")
        }
    }
}
