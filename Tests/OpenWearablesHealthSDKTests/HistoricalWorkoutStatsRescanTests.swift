import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Sole Mates Gate H.32 (2026-10-13) - Historical Workout-Statistics
/// Recovery.
///
/// Same testing discipline as HistoricalRouteRescanTests: nothing here
/// touches a real HealthKit store or network. `historicalRescanEnumerationOverrideForTests`
/// (shared with the route rescan - see that property's own usage) stands
/// in for HKWorkout enumeration; `StubURLProtocol` scripts the resend's
/// HTTP responses so `uploadCombinedPayload`'s real code runs for real.
final class HistoricalWorkoutStatsRescanTests: XCTestCase {

    private func fakeWorkout(start: Date = Date(timeIntervalSince1970: 1_700_000_000), distance: Double? = nil) -> HKWorkout {
        let quantity = distance.map { HKQuantity(unit: .meter(), doubleValue: $0) }
        return HKWorkout(
            activityType: .running, start: start, end: start.addingTimeInterval(1800),
            workoutEvents: nil, totalEnergyBurned: nil, totalDistance: quantity, metadata: nil
        )
    }

    // MARK: - Not signed in

    func testCannotStartWhenNotSignedIn() {
        withIsolatedSDK(accessToken: nil, refreshToken: nil) { sdk, _ in
            // Explicit, not leaked from another test's ordering - a
            // finite window must be configured for the "not signed in"
            // check below to be the one that actually fires.
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not query HealthKit when not signed in")
                completion(false, [], nil, false)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .notStarted)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Bounded-scan enforcement (mirrors WP #30 hardening)

    func testRefusesToStartWithNoFiniteSyncWindow() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(0)
            XCTAssertNil(sdk.syncStartDate(), "precondition: no finite sync window configured")

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not query HealthKit at all when the sync window is unbounded")
                completion(false, [], nil, false)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan { progress in
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
            sdk.startHistoricalWorkoutStatsRescan(maxWorkouts: 0) { progress in
                XCTAssertEqual(progress.status, .notStarted)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    func testEnumerationQueryFailureLandsOnATerminalStatusNotStuckRunning() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(false, [], nil, false)
            }
            let expectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .failedEnumerationQuery)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
            XCTAssertEqual(sdk.historicalWorkoutStatsRescanProgress().status, .failedEnumerationQuery)

            sdk.pauseHistoricalWorkoutStatsRescan()
            XCTAssertEqual(sdk.historicalWorkoutStatsRescanProgress().status, .failedEnumerationQuery, "pause must be a no-op against a non-running status")
        }
    }

    // MARK: - Resend behavior

    /// The core recovery path: a workout already synced once (the rescan
    /// doesn't know or care whether it's "already synced" - that's the
    /// point, it just resends) is rebuilt from the CURRENT HKWorkout
    /// state and resent, carrying the same HealthKit UUID.
    func testResendsEachEnumeratedWorkoutPreservingItsHealthKitUUID() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workout = fakeWorkout(distance: 5070) // the Oct 12 workout, now with distance newly readable
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, [workout], nil, true)
                } else {
                    completion(true, [], nil, true)
                }
            }
            StubURLProtocol.install { _ in .status(200) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                XCTAssertEqual(progress.scannedCount, 1)
                XCTAssertEqual(progress.resentCount, 1)
                XCTAssertEqual(progress.resendFailedCount, 0)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            let recorded = StubURLProtocol.recorded
            XCTAssertEqual(recorded.count, 1)
            let workoutsJson = recorded.first?.json?["data"] as? [String: Any]
            let workoutsArray = workoutsJson?["workouts"] as? [[String: Any]]
            XCTAssertEqual(workoutsArray?.first?["id"] as? String, workout.uuid.uuidString, "resend must carry the SAME HealthKit UUID as the original sync - this is the server's identity key")
        }
    }

    func testResendFailureIsCountedAndDoesNotHaltTheRun() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workouts = (0..<2).map { fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 100_000)) }
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, workouts, nil, true)
                } else {
                    completion(true, [], nil, true)
                }
            }
            StubURLProtocol.install { _ in .status(500) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .completed, "a resend failure is per-workout, not fatal to the run")
                XCTAssertEqual(progress.scannedCount, 2)
                XCTAssertEqual(progress.resentCount, 0)
                XCTAssertEqual(progress.resendFailedCount, 2)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Idempotency / retry

    /// Resending the same workout twice (e.g. a second invocation after
    /// `.completed`) must be a no-op the second time - `.completed`
    /// short-circuits before any HealthKit query or network call.
    func testCompletedRunIsANoOpOnASecondCall() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(true, [], nil, true)
            }
            let firstExpectation = expectation(description: "first completion")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                firstExpectation.fulfill()
            }
            wait(for: [firstExpectation], timeout: 2)

            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("a completed run must not re-query HealthKit")
                completion(true, [], nil, true)
            }
            let secondExpectation = expectation(description: "second completion")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                secondExpectation.fulfill()
            }
            wait(for: [secondExpectation], timeout: 2)
        }
    }

    /// Retrying after `.failedEnumerationQuery` must reach HealthKit
    /// again and can still succeed - mirrors the route rescan's own
    /// equivalent test.
    func testRetryAfterEnumerationFailureReachesHealthKitAgain() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                completion(false, [], nil, false)
            }
            let firstExpectation = expectation(description: "first completion")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .failedEnumerationQuery)
                firstExpectation.fulfill()
            }
            wait(for: [firstExpectation], timeout: 2)

            var retried = false
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                retried = true
                completion(true, [], nil, true)
            }
            let secondExpectation = expectation(description: "retry completion")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                secondExpectation.fulfill()
            }
            wait(for: [secondExpectation], timeout: 2)
            XCTAssertTrue(retried)
        }
    }

    // MARK: - Workout-limit resumption

    func testStopsAtTheWorkoutLimitAndCanResume() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            let workouts = (0..<5).map { fakeWorkout(start: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 100_000)) }
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, workouts, nil, true)
                } else {
                    XCTFail("must not fetch another chunk within the same bounded invocation")
                    completion(true, [], nil, true)
                }
            }
            StubURLProtocol.install { _ in .status(200) }

            let firstExpectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan(maxWorkouts: 3) { progress in
                XCTAssertEqual(progress.status, .stoppedAtWorkoutLimit)
                XCTAssertEqual(progress.scannedCount, 3, "must stop exactly at the cap, not process all 5")
                firstExpectation.fulfill()
            }
            wait(for: [firstExpectation], timeout: 2)

            var secondRunOlderThan: Date? = Date() // sentinel - must be reassigned
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                secondRunOlderThan = olderThan
                completion(true, [], nil, true)
            }
            let secondExpectation = expectation(description: "resume completion")
            sdk.startHistoricalWorkoutStatsRescan(maxWorkouts: 10) { progress in
                XCTAssertEqual(progress.status, .completed)
                secondExpectation.fulfill()
            }
            wait(for: [secondExpectation], timeout: 2)
            XCTAssertEqual(secondRunOlderThan, workouts[2].endDate, "resume must pick up exactly where the cursor left off, not restart from the beginning")
        }
    }

    // MARK: - Never touches anchors (requirement 9)

    func testNeverResetsAnchorsOrSyncSession() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            // Seed a real anchor + a resumable sync session the way
            // ordinary incremental sync would, so a regression that
            // touches either is actually observable.
            let sampleType = HKObjectType.workoutType()
            sdk.saveAnchor(HKQueryAnchor(fromValue: 42), for: sampleType)
            XCTAssertNotNil(sdk.loadAnchor(for: sampleType), "precondition: an anchor exists before the rescan runs")

            let workout = fakeWorkout()
            sdk.historicalRescanEnumerationOverrideForTests = { olderThan, _, _, completion in
                if olderThan == nil {
                    completion(true, [workout], nil, true)
                } else {
                    completion(true, [], nil, true)
                }
            }
            StubURLProtocol.install { _ in .status(200) }

            let expectation = expectation(description: "completion called")
            sdk.startHistoricalWorkoutStatsRescan { progress in
                XCTAssertEqual(progress.status, .completed)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)

            XCTAssertNotNil(sdk.loadAnchor(for: sampleType), "a historical stats rescan must never clear the forward incremental-sync anchor")
        }
    }
}

// MARK: - Permission-expansion detection (requirement 8)

final class PermissionExpansionDetectionTests: XCTestCase {

    func testNoPreviousTypesMeansNoNewlyRequestedTypes() {
        // Fallback for "permission state cannot be determined": an empty
        // previous list (first-ever call, or a genuinely cleared
        // Keychain) must never be treated as "everything is new."
        let result = OpenWearablesHealthSDK.newlyRequestedTypes(
            effectiveTypes: [.workout, .steps, .distanceWalkingRunning],
            previouslyTrackedRawValues: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testDetectsAStrictSupersetAsNewlyRequested() {
        let result = OpenWearablesHealthSDK.newlyRequestedTypes(
            effectiveTypes: [.workout, .steps, .distanceWalkingRunning, .heartRate],
            previouslyTrackedRawValues: Set([HealthDataType.workout.rawValue, HealthDataType.steps.rawValue])
        )
        XCTAssertEqual(Set(result), Set([.distanceWalkingRunning, .heartRate]))
    }

    func testUnchangedTypeListProducesNoNewlyRequestedTypes() {
        let previous = Set([HealthDataType.workout.rawValue, HealthDataType.steps.rawValue])
        let result = OpenWearablesHealthSDK.newlyRequestedTypes(
            effectiveTypes: [.workout, .steps], previouslyTrackedRawValues: previous
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testTriggerIgnoresWorkoutAndWorkoutRouteAloneButFiresOnAnyOtherType() {
        withIsolatedSDK { sdk, _ in
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(14)
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                XCTFail("must not start a rescan for workout/workoutRoute alone")
                completion(true, [], nil, true)
            }
            sdk.triggerStatsRescanIfPermissionsExpanded(newlyRequestedTypes: [.workout, .workoutRoute])
            // Give any (incorrectly) started async rescan a chance to run.
            _ = waitUntil(timeout: 0.3) { false }
            XCTAssertEqual(sdk.historicalWorkoutStatsRescanProgress().status, .notStarted)

            var started = false
            sdk.historicalRescanEnumerationOverrideForTests = { _, _, _, completion in
                started = true
                completion(true, [], nil, true)
            }
            sdk.triggerStatsRescanIfPermissionsExpanded(newlyRequestedTypes: [.workout, .distanceWalkingRunning])
            XCTAssertTrue(waitUntil { started }, "a newly-requested quantity type must start the bounded stats rescan")
        }
    }
}
