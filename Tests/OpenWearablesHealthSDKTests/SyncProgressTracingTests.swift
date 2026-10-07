import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Sync Progress Tracing WP (2026-10-07) — minimal, purely additive logging
/// at the query/upload/progress boundaries, added to distinguish "the
/// HealthKit query found nothing," "an upload was attempted and what
/// happened," and "progress/anchors did or didn't advance" from each other.
/// Added because the app's own screen-level "watch_completed" signal was
/// confirmed (this WP's own investigation doc) to fire on a stale,
/// previously-persisted flag regardless of whether the current round's own
/// work had even started — none of these new lines change what any caller
/// does with a result; they only add logMessage() calls, which the host
/// app already relays verbatim to its on-device diagnostic log via
/// `onLog` (Sole_MatesApp.swift) — no new relay wiring was needed.
///
/// Query-boundary tracing (`TRACE_QUERY`, in `fetchOneChunkNewestFirst`/
/// `fetchOneChunkIncremental`) is not covered by an automated test here:
/// both call real `healthStore.execute(query:)` against a non-overridable
/// `let healthStore = HKHealthStore()` (OpenWearablesHealthSDK.swift:150),
/// and this suite has no existing precedent for mocking HealthKit itself —
/// doing so would be a larger refactor than this diagnostic change
/// warrants. Verified instead by direct code review: each `TRACE_QUERY`
/// call sits immediately beside an existing, already-production-proven
/// `logMessage` call (the ones already seen in real device logs this
/// round, e.g. "all data sent (newest first)", "complete", "N samples") —
/// same execution path, same three outcomes (error / empty / samples
/// found), confirmed to compile and not regress any of the other 74 tests
/// in this suite.
final class SyncProgressTracingTests: XCTestCase {

    private func captureLogs(_ sdk: OpenWearablesHealthSDK, _ body: () -> Void) -> [String] {
        var captured: [String] = []
        let previous = sdk.onLog
        sdk.onLog = { captured.append($0) }
        defer { sdk.onLog = previous }
        body()
        return captured
    }

    // MARK: - Anchor/progress persistence tracing (Session.swift)

    func testProgressTraceReportsAdvancementWhenStateExists() {
        withIsolatedSDK { sdk, _ in
            _ = sdk.startNewSyncState(fullExport: false, types: [HKObjectType.workoutType()])

            let logs = captureLogs(sdk) {
                sdk.updateTypeProgress(
                    typeIdentifier: HKObjectType.workoutType().identifier,
                    sentInChunk: 3, isComplete: true,
                    anchorData: Data("fake-anchor".utf8)
                )
            }

            let traceLines = logs.filter { $0.hasPrefix("TRACE_PROGRESS") }
            XCTAssertEqual(traceLines.count, 1, "expected exactly one trace line, got: \(logs)")
            let line = traceLines[0]
            XCTAssertTrue(line.contains("advanced=true"), line)
            XCTAssertTrue(line.contains("sentInChunk=3"), line)
            XCTAssertTrue(line.contains("isComplete=true"), line)
            XCTAssertTrue(line.contains("anchorSaved=true"), line)

            // Confirm the trace describes something that actually happened,
            // not just a line that says so: the state really did advance.
            let state = sdk.loadSyncSession()
            XCTAssertEqual(state?.totalSentCount, 3)
            XCTAssertTrue(state?.completedTypes.contains(HKObjectType.workoutType().identifier) ?? false)
        }
    }

    func testProgressTraceReportsNoAdvancementWithoutSyncState() {
        withIsolatedSDK { sdk, _ in
            sdk.clearSyncSession() // ensure no SyncState file exists

            let logs = captureLogs(sdk) {
                sdk.updateTypeProgress(
                    typeIdentifier: HKObjectType.workoutType().identifier,
                    sentInChunk: 5, isComplete: false, anchorData: nil
                )
            }

            let traceLines = logs.filter { $0.hasPrefix("TRACE_PROGRESS") }
            XCTAssertEqual(traceLines.count, 1, "expected exactly one trace line, got: \(logs)")
            XCTAssertTrue(traceLines[0].contains("advanced=false"), traceLines[0])
            XCTAssertTrue(traceLines[0].contains("reason=no_sync_state_to_update"), traceLines[0])

            // Confirm the trace describes something that actually happened:
            // no state file was created as a side effect of this call.
            XCTAssertNil(sdk.loadSyncSession())
        }
    }

    // MARK: - Upload start/completion tracing (Outbox.swift)

    private let payload: [String: Any] = [
        "provider": "apple",
        "data": ["records": [], "sleep": [], "workouts": []]
    ]

    func testUploadStartTraceCorrelatesWithOutcomeOnSuccess() {
        withIsolatedSDK { sdk, _ in
            guard let endpoint = sdk.syncEndpoint, let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            defer { sdk.finishSync(generation: generation) }

            StubURLProtocol.install { _ in .status(200) }

            var outcome: Bool?
            let logs = captureLogs(sdk) {
                sdk.uploadCombinedPayload(
                    payload: payload, endpoint: endpoint, credential: "access-1",
                    generation: generation, sampleCount: 7
                ) { outcome = $0 }
                waitUntil { outcome != nil }
            }

            XCTAssertEqual(outcome, true)

            guard let startLine = logs.first(where: { $0.hasPrefix("TRACE_UPLOAD_START") }) else {
                return XCTFail("missing TRACE_UPLOAD_START, got: \(logs)")
            }
            XCTAssertTrue(startLine.contains("sampleCount=7"), startLine)

            guard let outcomeLine = logs.first(where: { $0.hasPrefix("upload=sync") }) else {
                return XCTFail("missing the existing upload outcome line, got: \(logs)")
            }
            XCTAssertTrue(outcomeLine.contains("status=200"), outcomeLine)

            // Same correlation id ties the new start trace to the existing
            // outcome line — "req=<uuid>" is a token in both messages.
            func requestId(from line: String) -> String? {
                line.split(separator: " ").first { $0.hasPrefix("req=") }.map(String.init)
            }
            XCTAssertEqual(requestId(from: startLine), requestId(from: outcomeLine))
        }
    }

    func testUploadStartTraceStillFiresOnFailure() {
        withIsolatedSDK { sdk, _ in
            guard let endpoint = sdk.syncEndpoint, let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            defer { sdk.finishSync(generation: generation) }

            StubURLProtocol.install { _ in .status(500) }

            var outcome: Bool?
            let logs = captureLogs(sdk) {
                sdk.uploadCombinedPayload(
                    payload: payload, endpoint: endpoint, credential: "access-1",
                    generation: generation, sampleCount: 4
                ) { outcome = $0 }
                waitUntil { outcome != nil }
            }

            XCTAssertEqual(outcome, false, "a 500 must not report success")
            XCTAssertTrue(
                logs.contains { $0.hasPrefix("TRACE_UPLOAD_START") && $0.contains("sampleCount=4") },
                "the start trace must fire regardless of the eventual outcome, got: \(logs)"
            )
        }
    }

    func testUploadStartTraceDefaultsWhenSampleCountNotSupplied() {
        withIsolatedSDK { sdk, _ in
            guard let endpoint = sdk.syncEndpoint, let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            defer { sdk.finishSync(generation: generation) }

            StubURLProtocol.install { _ in .status(200) }

            var outcome: Bool?
            let logs = captureLogs(sdk) {
                // Omits sampleCount, exactly as every pre-existing call site
                // not updated for this WP still would.
                sdk.uploadCombinedPayload(
                    payload: payload, endpoint: endpoint, credential: "access-1", generation: generation
                ) { outcome = $0 }
                waitUntil { outcome != nil }
            }

            XCTAssertEqual(outcome, true)
            XCTAssertTrue(
                logs.contains { $0.hasPrefix("TRACE_UPLOAD_START") && $0.contains("sampleCount=-1") },
                "an un-migrated call site must default cleanly, not crash or omit the trace, got: \(logs)"
            )
        }
    }
}
