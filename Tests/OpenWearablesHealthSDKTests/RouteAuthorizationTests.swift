//
//  RouteAuthorizationTests.swift
//  OpenWearablesHealthSDKTests
//
//  Map Roadmap #27 - Apple Route Ingestion Foundation (2026-10-04).
//  Covers the PURE logic this WP added - no real HKHealthStore call, so
//  these run in any environment (no device/simulator HealthKit
//  entitlement dance needed). The real on-device route query path is
//  proven separately via the bounded device proof (not unit-testable:
//  HKWorkoutRouteQuery requires real HealthKit data).
//
import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

final class RouteAuthorizationTests: XCTestCase {

    // MARK: - normalizedTypesForAuthorization (the crash guard)

    func testWorkoutRouteAloneGetsWorkoutAdded() {
        let result = OpenWearablesHealthSDK.normalizedTypesForAuthorization([.workoutRoute])
        XCTAssertTrue(result.contains(.workout), "workoutRoute alone must never be requestable without workout")
        XCTAssertTrue(result.contains(.workoutRoute))
    }

    func testWorkoutAndWorkoutRouteTogetherUnchanged() {
        let result = OpenWearablesHealthSDK.normalizedTypesForAuthorization([.workout, .workoutRoute])
        XCTAssertEqual(Set(result), Set([.workout, .workoutRoute]))
    }

    func testWorkoutAloneUnchanged() {
        let result = OpenWearablesHealthSDK.normalizedTypesForAuthorization([.workout])
        XCTAssertEqual(result, [.workout])
    }

    func testUnrelatedTypesUnchanged() {
        let result = OpenWearablesHealthSDK.normalizedTypesForAuthorization([.steps, .heartRate, .sleep])
        XCTAssertEqual(result, [.steps, .heartRate, .sleep])
    }

    func testEmptyTypesUnchanged() {
        let result = OpenWearablesHealthSDK.normalizedTypesForAuthorization([])
        XCTAssertEqual(result, [])
    }

    func testWorkoutRoutePlusUnrelatedTypesStillGetsWorkoutAdded() {
        let result = OpenWearablesHealthSDK.normalizedTypesForAuthorization([.steps, .workoutRoute])
        XCTAssertTrue(result.contains(.workout))
        XCTAssertTrue(result.contains(.workoutRoute))
        XCTAssertTrue(result.contains(.steps))
    }

    // MARK: - HealthDataType.workoutRoute -> HKSeriesType.workoutRoute()

    func testWorkoutRouteMapsToHKSeriesType() {
        let sampleType = HealthDataType.workoutRoute.toHKSampleType()
        XCTAssertEqual(sampleType, HKSeriesType.workoutRoute())
    }

    // MARK: - getSyncableTypes() excludes workoutRoute; getQueryableTypes() keeps it

    func testGetSyncableTypesExcludesWorkoutRouteButGetQueryableTypesKeepsIt() {
        let sdk = OpenWearablesHealthSDK.shared
        sdk.requestAuthorization(types: [.workout, .workoutRoute]) { _ in }
        // requestAuthorization sets trackedTypes synchronously before the
        // (real HealthKit, possibly-not-granted-in-CI) async callback -
        // sufficient for this comparison.
        let queryable = sdk.getQueryableTypes()
        let syncable = sdk.getSyncableTypes()

        let routeIdentifier = HKSeriesType.workoutRoute().identifier
        XCTAssertTrue(queryable.contains { $0.identifier == routeIdentifier }, "auth read-set must still include workoutRoute")
        XCTAssertFalse(syncable.contains { $0.identifier == routeIdentifier }, "generic sync loop must never include workoutRoute")
        XCTAssertTrue(syncable.contains { $0.identifier == HKObjectType.workoutType().identifier }, "workout itself must remain syncable")
    }
}
