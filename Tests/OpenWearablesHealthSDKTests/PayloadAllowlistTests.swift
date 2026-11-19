import XCTest
@testable import OpenWearablesHealthSDK

/// GDPR-04 — on-device payload allowlist (Internal/PayloadAllowlist.swift). Synthetic payloads only.
final class PayloadAllowlistTests: XCTestCase {
    private let prohibited = ["minHeartRate", "averageHeartRate", "maxHeartRate", "averageRunningPower", "cyclingPower", "cyclingCadence",
                              "stepCount", "activeEnergyBurned", "basalEnergyBurned", "averageRunningStrideLength", "averageVerticalOscillation",
                              "averageGroundContactTime", "averageMETs", "weatherTemperature", "weatherHumidity", "averageSpeed", "maxSpeed", "lapLength"]

    private func heavyPayload() -> [String: Any] {
        var values: [[String: Any]] = prohibited.map { ["type": $0, "value": 151, "unit": "x"] }
        values += [["type": "duration", "value": 3600, "unit": "s"], ["type": "distance", "value": 10000, "unit": "m"], ["type": "elevationAscended", "value": 55, "unit": "m"]]
        let workout: [String: Any] = [
            "id": "w1", "parentId": NSNull(), "type": "running", "startDate": "2026-11-01T07:00:00Z", "endDate": "2026-11-01T08:00:00Z", "zoneOffset": "+01:00",
            "source": ["appId": "com.apple.health", "name": "Synthetic Person's Apple Watch", "deviceName": "Synthetic Person's Apple Watch", "deviceModel": "Watch",
                       "deviceType": "watch", "deviceManufacturer": "Apple", "deviceId": NSNull(), "deviceHardwareVersion": "Watch7,4", "deviceSoftwareVersion": "11.0",
                       "operatingSystemVersion": ["majorVersion": 11, "minorVersion": 0, "patchVersion": 0]],
            "title": "Synthetic title", "notes": "free text", "values": values, "segments": NSNull(),
            "laps": [["metadata": ["HKWeatherTemperature": 12]]],
            "route": [["t": "2026-11-01T07:00:00Z", "lat": 55.1, "lng": 12.1, "alt": 10, "hAcc": 5, "vAcc": 3, "segmentIndex": 0]],
            "samples": NSNull(), "metadata": ["HKAverageMETs": 9],
        ]
        return ["provider": "apple", "sdkVersion": "0.19.0", "syncSessionId": "s1",
                "data": ["workouts": [workout], "records": [["type": "HKQuantityTypeIdentifierDistanceWalkingRunning", "value": 12]], "sleep": [["stage": "deep"]]]]
    }

    private func firstWorkout(_ p: [String: Any]) -> [String: Any] {
        ((p["data"] as? [String: Any])?["workouts"] as? [[String: Any]])?.first ?? [:]
    }

    func testOnlyAllowlistedStatisticsAreSent() {
        let w = firstWorkout(PayloadAllowlist.apply(heavyPayload()))
        let types = Set((w["values"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String })
        XCTAssertEqual(types, ["duration", "distance", "elevationAscended"])
    }

    func testNoProhibitedValueOrFreeTextLeavesTheDevice() throws {
        let out = PayloadAllowlist.apply(heavyPayload())
        let json = String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8) ?? ""
        for needle in ["151", "HeartRate", "Power", "Cadence", "stepCount", "Energy", "METs", "weather", "Weather", "Synthetic title", "free text", "laps", "Watch7,4", "operatingSystemVersion", "Synthetic Person", "hAcc", "vAcc"] {
            XCTAssertFalse(json.contains(needle), needle)
        }
    }

    func testRecordsAndSleepAreNeverSent() {
        let data = PayloadAllowlist.apply(heavyPayload())["data"] as? [String: Any]
        XCTAssertEqual((data?["records"] as? [Any])?.count, 0)
        XCTAssertEqual((data?["sleep"] as? [Any])?.count, 0)
    }

    func testCompetitionFieldsRouteAndProvenanceAreKept() {
        let out = PayloadAllowlist.apply(heavyPayload())
        let w = firstWorkout(out)
        XCTAssertEqual(w["id"] as? String, "w1")
        XCTAssertEqual(w["type"] as? String, "running")
        XCTAssertEqual(w["zoneOffset"] as? String, "+01:00")
        let route = w["route"] as? [[String: Any]]
        XCTAssertEqual(route?.count, 1)
        XCTAssertEqual(Set(route?.first?.keys.map { $0 } ?? []), ["t", "lat", "lng", "alt", "segmentIndex"])
        let src = w["source"] as? [String: Any]
        XCTAssertEqual(src?["name"] as? String, "Apple Watch")
        XCTAssertEqual(src?["deviceName"] as? String, "Apple Watch")
        XCTAssertEqual(src?["appId"] as? String, "com.apple.health")
        XCTAssertNil(src?["deviceHardwareVersion"])
        XCTAssertEqual(out["syncSessionId"] as? String, "s1")
        XCTAssertEqual(out["provider"] as? String, "apple")
    }

    func testDeviceNameRules() {
        XCTAssertEqual(PayloadAllowlist.minimizeDeviceName("Alex’s iPhone") as? String, "iPhone")
        XCTAssertEqual(PayloadAllowlist.minimizeDeviceName("iPhone von Synthetic") as? String, "iPhone")
        XCTAssertEqual(PayloadAllowlist.minimizeDeviceName("Connect") as? String, "Connect")
        XCTAssertTrue(PayloadAllowlist.minimizeDeviceName("  ") is NSNull)
    }

    func testOnlyWorkoutsAreSyncable() {
        XCTAssertTrue(PayloadAllowlist.isSyncableIdentifier("HKWorkoutTypeIdentifier"))
        XCTAssertFalse(PayloadAllowlist.isSyncableIdentifier("HKQuantityTypeIdentifierDistanceWalkingRunning"))
        XCTAssertFalse(PayloadAllowlist.isSyncableIdentifier("HKQuantityTypeIdentifierHeartRate"))
    }
}
