import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Sole Mates WP #30 (2026-10-08) - Historical GPS Route Recovery.
///
/// Same testing discipline as RouteRetryTests: nothing here touches a
/// real HealthKit store. `historicalRescanEnumerationOverrideForTests`
/// stands in for the one piece that genuinely requires HealthKit
/// (enumerating historical HKWorkouts); `historicalRescanRouteLookupOverrideForTests`
/// stands in for fetchRoutePayload. Everything else (persisted
/// progress, pause/cancel/resume, the resend's own payload shape) runs
/// for real.
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

    // MARK: - Fresh start

    func testFreshStartQueriesWithNilOlderThanCursor() {
        withIsolatedSDK { sdk, _ in
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

    // MARK: - Route found -> resend

    func testRouteFoundResendsThroughTheNormalSyncPayloadShape() {
        withIsolatedSDK { sdk, _ in
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [workout], nil, true)
            }
            sdk.historicalRescanRouteLookupOverrideForTests = { [weak self] _, completion in
                completion(self?.fakeRoutePoints)
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

    // MARK: - No route found -> no network call

    func testNoRouteFoundDoesNotResendOrCallNetwork() {
        withIsolatedSDK { sdk, _ in
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [workout], nil, true)
            }
            sdk.historicalRescanRouteLookupOverrideForTests = { _, completion in
                completion(nil)  // genuinely no route upstream — must not be fabricated
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
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Multiple workouts in one chunk

    func testMultipleWorkoutsInOneChunkAreAllProcessed() {
        withIsolatedSDK { sdk, _ in
            let workouts = [
                fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000)),
                fakeWorkout(start: Date(timeIntervalSince1970: 1_700_100_000)),
                fakeWorkout(start: Date(timeIntervalSince1970: 1_700_200_000)),
            ]
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, workouts, nil, true)
            }
            sdk.historicalRescanRouteLookupOverrideForTests = { [weak self] workout, completion in
                // Only the middle one has a route — exercises the mixed case.
                completion(workout.startDate == workouts[1].startDate ? self?.fakeRoutePoints : nil)
            }
            StubURLProtocol.install { _ in .status(202) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalRouteRescan { progress in
                XCTAssertEqual(progress.scannedCount, 3)
                XCTAssertEqual(progress.routeFoundCount, 1)
                XCTAssertEqual(progress.resentCount, 1)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Pause between chunks, not mid-chunk

    func testPauseRequestedDuringAChunkStillLetsThatChunkFinish() {
        withIsolatedSDK { sdk, _ in
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
            sdk.historicalRescanRouteLookupOverrideForTests = { _, completion in
                sdk.pauseHistoricalRouteRescan()  // requested mid-first-chunk
                completion(nil)
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
            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, [workout], workout.endDate, false)
                } else {
                    XCTFail("must not start a second chunk after cancellation")
                    completion(true, [], nil, true)
                }
            }
            sdk.historicalRescanRouteLookupOverrideForTests = { _, completion in
                sdk.cancelHistoricalRouteRescan()
                completion(nil)
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
            sdk.historicalRescanRouteLookupOverrideForTests = { _, completion in
                sdk.pauseHistoricalRouteRescan()
                completion(nil)
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
}
