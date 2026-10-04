import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Map Roadmap #27 Stage F - Apple Route Availability Race Remediation.
///
/// `OpenWearablesHealthSDK.PendingRouteRetry` entries are written and read
/// directly from disk, the same way `OutboxRetryTests`' `writeLeftover`
/// does - this both proves the store survives a process boundary (nothing
/// here is ever held only in memory) and avoids needing a real HealthKit
/// authorization/store, which the whole suite deliberately never touches.
/// `routeRetryLookupOverrideForTests` stands in for the one piece that
/// genuinely requires HealthKit (refetching a workout by UUID and
/// querying its route) - see RouteRetry.swift's own doc comment on why
/// that seam exists.
final class RouteRetryTests: XCTestCase {

    private func fakeWorkout(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> HKWorkout {
        HKWorkout(
            activityType: .running, start: start, end: start.addingTimeInterval(180),
            workoutEvents: nil, totalEnergyBurned: nil, totalDistance: nil, metadata: nil
        )
    }

    private let fakeRoutePoints: [[String: Any]] = [
        ["t": "2026-10-04T12:58:46Z", "lat": 0.0, "lng": 0.0],
        ["t": "2026-10-04T12:58:47Z", "lat": 0.0, "lng": 0.0],
    ]

    private func pendingRetryFileURL(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("pending_apple_route_retries.json")
    }

    @discardableResult
    private func writePendingRetry(
        in stateDirectory: URL, uuid: UUID = UUID(),
        firstMissedAt: Date, lastAttemptAt: Date? = nil, attemptCount: Int = 0
    ) -> OpenWearablesHealthSDK.PendingRouteRetry {
        let item = OpenWearablesHealthSDK.PendingRouteRetry(
            workoutUUID: uuid, firstMissedAt: firstMissedAt, lastAttemptAt: lastAttemptAt, attemptCount: attemptCount
        )
        let data = try! JSONEncoder().encode([item])
        try? data.write(to: pendingRetryFileURL(in: stateDirectory))
        return item
    }

    private func readPendingRetries(in stateDirectory: URL) -> [OpenWearablesHealthSDK.PendingRouteRetry] {
        guard let data = try? Data(contentsOf: pendingRetryFileURL(in: stateDirectory)),
              let items = try? JSONDecoder().decode([OpenWearablesHealthSDK.PendingRouteRetry].self, from: data) else {
            return []
        }
        return items
    }

    // MARK: - Recording a miss

    func testRecordingTheSameWorkoutTwiceDoesNotDuplicateOrResetFirstMissedAt() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()

            sdk.recordPendingRouteRetryIfNeeded(for: workout)
            let firstEntries = readPendingRetries(in: stateDirectory)
            XCTAssertEqual(firstEntries.count, 1)
            let firstMissedAt = firstEntries[0].firstMissedAt

            sdk.recordPendingRouteRetryIfNeeded(for: workout)
            let secondEntries = readPendingRetries(in: stateDirectory)

            XCTAssertEqual(secondEntries.count, 1, "a repeat miss for the same workout must not create a second entry")
            XCTAssertEqual(secondEntries[0].firstMissedAt, firstMissedAt, "a repeat miss must not reset the retry clock")
        }
    }

    // MARK: - Not yet eligible

    func testItemYoungerThanBackoffFloorIsLeftUntouched() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                XCTFail("must not query HealthKit before the backoff floor elapses")
                completion(nil, nil)
            }
            let item = writePendingRetry(in: stateDirectory, firstMissedAt: Date())

            sdk.retryPendingRoutesIfPossible()

            let remaining = readPendingRetries(in: stateDirectory)
            XCTAssertEqual(remaining, [item])
        }
    }

    // MARK: - Delayed route attaches

    func testDelayedRouteFoundOnEligibleRetryResendsAndClearsPendingEntry() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()
            writePendingRetry(in: stateDirectory, uuid: workout.uuid, firstMissedAt: Date().addingTimeInterval(-20))

            sdk.routeRetryLookupOverrideForTests = { [weak self] uuid, completion in
                XCTAssertEqual(uuid, workout.uuid)
                completion(workout, self?.fakeRoutePoints)
            }
            StubURLProtocol.install { _ in .status(202) }

            sdk.retryPendingRoutesIfPossible()

            XCTAssertTrue(waitUntil { StubURLProtocol.requests(matching: "/sync").count == 1 })
            let resend = StubURLProtocol.recorded(matching: "/sync").first
            let workouts = (resend?.json?["data"] as? [String: Any])?["workouts"] as? [[String: Any]]
            XCTAssertEqual(workouts?.count, 1, "resends exactly the one workout, through the normal sync payload shape")
            XCTAssertNotNil(workouts?.first?["route"], "the late route must be attached to the resend")

            XCTAssertTrue(waitUntil { readPendingRetries(in: stateDirectory).isEmpty })
        }
    }

    // MARK: - Route still missing on retry

    func testRouteStillMissingMarksAttemptWithoutResending() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()
            writePendingRetry(in: stateDirectory, uuid: workout.uuid, firstMissedAt: Date().addingTimeInterval(-20))

            sdk.routeRetryLookupOverrideForTests = { uuid, completion in
                completion(workout, nil)  // workout still exists, route still not there
            }
            StubURLProtocol.install { _ in
                XCTFail("must not resend a workout with no route")
                return .status(202)
            }

            sdk.retryPendingRoutesIfPossible()

            XCTAssertTrue(waitUntil {
                let items = readPendingRetries(in: stateDirectory)
                return items.count == 1 && items[0].attemptCount == 1
            })
            XCTAssertEqual(StubURLProtocol.requests.count, 0)
        }
    }

    // MARK: - Stage G: attempt count governs cadence only, never termination

    /// Four early misses - exactly the count that used to prune the entry
    /// under Stage F's original policy - must now only advance it into
    /// the slow phase, never remove it.
    func testFourEarlyMissesDoNotPruneTheEntry() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()
            sdk.routeRetryLookupOverrideForTests = { _, completion in completion(workout, nil) }

            writePendingRetry(in: stateDirectory, uuid: workout.uuid, firstMissedAt: Date().addingTimeInterval(-20))
            for _ in 0..<OpenWearablesHealthSDK.routeRetryEarlyBackoff.count {
                sdk.retryPendingRoutesIfPossible()
                XCTAssertTrue(waitUntil {
                    let items = readPendingRetries(in: stateDirectory)
                    return items.count == 1 && items[0].lastAttemptAt != nil
                })
                // Force the next attempt's floor to have already elapsed so
                // the loop doesn't spend real wall-clock time waiting on
                // the 30-minute early-phase step.
                var items = readPendingRetries(in: stateDirectory)
                items[0].lastAttemptAt = Date().addingTimeInterval(-3600)
                try! JSONEncoder().encode(items).write(to: pendingRetryFileURL(in: stateDirectory))
            }

            let after = readPendingRetries(in: stateDirectory)
            XCTAssertEqual(after.count, 1, "four early misses must not terminate the entry")
            XCTAssertEqual(after[0].attemptCount, OpenWearablesHealthSDK.routeRetryEarlyBackoff.count)
        }
    }

    func testAfterEarlyPhaseEligibilityUsesTheSlowInterval() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                XCTFail("must not query HealthKit before the slow-phase floor elapses")
                completion(nil, nil)
            }
            // Early phase exhausted (attemptCount == early backoff count),
            // but only 10 minutes since the last attempt - well short of
            // the ~hourly slow-phase floor.
            let item = writePendingRetry(
                in: stateDirectory, firstMissedAt: Date().addingTimeInterval(-2 * 3600),
                lastAttemptAt: Date().addingTimeInterval(-600), attemptCount: OpenWearablesHealthSDK.routeRetryEarlyBackoff.count
            )

            sdk.retryPendingRoutesIfPossible()

            XCTAssertEqual(readPendingRetries(in: stateDirectory), [item])
        }
    }

    /// Simulates several opportunistic triggers (foreground/unlock/observer)
    /// landing inside the same slow-phase hour - each must be a complete
    /// no-op, never touching HealthKit.
    func testRepeatedTriggersWithinTheSlowIntervalCauseNoAdditionalHealthKitQueries() {
        withIsolatedSDK { sdk, stateDirectory in
            var queryCount = 0
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                queryCount += 1
                completion(nil, nil)
            }
            writePendingRetry(
                in: stateDirectory, firstMissedAt: Date().addingTimeInterval(-2 * 3600),
                lastAttemptAt: Date().addingTimeInterval(-600), attemptCount: OpenWearablesHealthSDK.routeRetryEarlyBackoff.count
            )

            for _ in 0..<5 { sdk.retryPendingRoutesIfPossible() }

            XCTAssertEqual(queryCount, 0, "a trigger inside the slow-phase interval must not reach HealthKit at all")
        }
    }

    func testRouteFoundDuringSlowPhaseSucceedsAndClearsTheEntry() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()
            writePendingRetry(
                in: stateDirectory, uuid: workout.uuid, firstMissedAt: Date().addingTimeInterval(-3 * 3600),
                lastAttemptAt: Date().addingTimeInterval(-3700), attemptCount: OpenWearablesHealthSDK.routeRetryEarlyBackoff.count + 2
            )
            sdk.routeRetryLookupOverrideForTests = { [weak self] _, completion in
                completion(workout, self?.fakeRoutePoints)
            }
            StubURLProtocol.install { _ in .status(202) }

            sdk.retryPendingRoutesIfPossible()

            XCTAssertTrue(waitUntil { StubURLProtocol.requests(matching: "/sync").count == 1 })
            XCTAssertTrue(waitUntil { readPendingRetries(in: stateDirectory).isEmpty })
        }
    }

    func testAgeUnderTwentyFourHoursNeverExpiresRegardlessOfAttemptCount() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()
            // Route genuinely still missing (workout exists, no route) -
            // not "workout deleted," which is the nil-workout case covered
            // by testWorkoutNoLongerInHealthKitRemovesPendingEntryWithoutResend.
            sdk.routeRetryLookupOverrideForTests = { _, completion in completion(workout, nil) }
            // Many more misses than the old attempt-count limit ever allowed,
            // but still well under 24h old - must survive.
            let item = writePendingRetry(
                in: stateDirectory, uuid: workout.uuid, firstMissedAt: Date().addingTimeInterval(-23 * 3600),
                lastAttemptAt: Date().addingTimeInterval(-3700), attemptCount: 50
            )

            sdk.retryPendingRoutesIfPossible()

            XCTAssertTrue(waitUntil { readPendingRetries(in: stateDirectory).count == 1 })
            let after = readPendingRetries(in: stateDirectory).first
            XCTAssertEqual(after?.workoutUUID, item.workoutUUID, "age alone governs termination - attempt count must not expire it")
        }
    }

    func testAgeAtOrPastTwentyFourHoursPrunesTheEntry() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                XCTFail("an item past max age must be pruned before any HealthKit lookup")
                completion(nil, nil)
            }
            writePendingRetry(
                in: stateDirectory, firstMissedAt: Date().addingTimeInterval(-25 * 3600),
                lastAttemptAt: Date().addingTimeInterval(-3600), attemptCount: 1
            )

            sdk.retryPendingRoutesIfPossible()

            XCTAssertTrue(waitUntil { readPendingRetries(in: stateDirectory).isEmpty })
        }
    }

    /// Protected-data-unavailable right at the edge of the 24h window must
    /// still be a pure skip - it must not be treated as a confirming miss
    /// that would otherwise justify expiry, and it must not itself expire
    /// the entry early.
    func testProtectedDataUnavailableNearExpiryDoesNotCountAsAGenuineMiss() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.protectedDataAvailableOverrideForTests = false
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                XCTFail("must not query HealthKit while protected data is unavailable")
                completion(nil, nil)
            }
            let item = writePendingRetry(
                in: stateDirectory, firstMissedAt: Date().addingTimeInterval(-23.9 * 3600),
                lastAttemptAt: Date().addingTimeInterval(-3700), attemptCount: 10
            )

            sdk.retryPendingRoutesIfPossible()

            XCTAssertEqual(readPendingRetries(in: stateDirectory), [item], "a skip near expiry must leave the entry exactly as it was")
        }
    }

    // MARK: - Workout deleted on-device

    func testWorkoutNoLongerInHealthKitRemovesPendingEntryWithoutResend() {
        withIsolatedSDK { sdk, stateDirectory in
            let uuid = UUID()
            writePendingRetry(in: stateDirectory, uuid: uuid, firstMissedAt: Date().addingTimeInterval(-20))

            sdk.routeRetryLookupOverrideForTests = { _, completion in completion(nil, nil) }
            StubURLProtocol.install { _ in
                XCTFail("must not resend a workout that no longer exists")
                return .status(202)
            }

            sdk.retryPendingRoutesIfPossible()

            XCTAssertTrue(waitUntil { readPendingRetries(in: stateDirectory).isEmpty })
            XCTAssertEqual(StubURLProtocol.requests.count, 0)
        }
    }

    // MARK: - Resend failure must not consume a backoff step

    func testFailedResendLeavesPendingEntryUnchangedForRetryAtTheSameEligibility() {
        withIsolatedSDK { sdk, stateDirectory in
            let workout = fakeWorkout()
            let original = writePendingRetry(in: stateDirectory, uuid: workout.uuid, firstMissedAt: Date().addingTimeInterval(-20))

            sdk.routeRetryLookupOverrideForTests = { [weak self] _, completion in
                completion(workout, self?.fakeRoutePoints)
            }
            StubURLProtocol.install { _ in .status(500) }

            sdk.retryPendingRoutesIfPossible()
            XCTAssertTrue(waitUntil { StubURLProtocol.requests.count == 1 })

            let remaining = readPendingRetries(in: stateDirectory)
            XCTAssertEqual(remaining, [original], "a network/auth failure is not 'no route yet' and must not advance attemptCount or lastAttemptAt")
        }
    }

    // MARK: - Protected data unavailable

    func testProtectedDataUnavailableSkipsWithoutConsumingAnAttempt() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.protectedDataAvailableOverrideForTests = false
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                XCTFail("must not query HealthKit while protected data is unavailable")
                completion(nil, nil)
            }
            let item = writePendingRetry(in: stateDirectory, firstMissedAt: Date().addingTimeInterval(-20))

            sdk.retryPendingRoutesIfPossible()

            XCTAssertEqual(readPendingRetries(in: stateDirectory), [item])
        }
    }

    // MARK: - Mutual exclusion with a live sync

    func testSkipsWhileASyncRunIsLive() {
        withIsolatedSDK { sdk, stateDirectory in
            sdk.routeRetryLookupOverrideForTests = { _, completion in
                XCTFail("a retry pass must not run while a real sync owns the slot")
                completion(nil, nil)
            }
            let item = writePendingRetry(in: stateDirectory, firstMissedAt: Date().addingTimeInterval(-20))

            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not claim the sync slot")
            }
            defer { sdk.finishSync(generation: generation) }

            sdk.retryPendingRoutesIfPossible()

            XCTAssertEqual(readPendingRetries(in: stateDirectory), [item])
        }
    }
}
