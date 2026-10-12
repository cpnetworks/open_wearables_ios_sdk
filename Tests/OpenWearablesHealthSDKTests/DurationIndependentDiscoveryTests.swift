import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Duration-Independent Discovery WP (2026-10-12) — P0 Nebu incident
/// (Sole Mates), Gate H.
///
/// Root cause: `fetchOneChunkIncremental` and `captureAnchorStep` both
/// applied a `syncStartDate()`-bound predicate to their
/// `HKAnchoredObjectQuery` calls — the ONGOING, anchor-driven sync path
/// reached after a full export has already completed. An anchored
/// query's whole purpose is to report every add/update/delete since the
/// last anchor regardless of a sample's own `startDate`; bounding it by
/// date silently excluded any workout whose own start predated
/// `syncDaysBack` (7 days by default) from EVERY later ordinary
/// background sync — a 32-hour or 100-hour workout, or any workout
/// synced to HealthKit more than `syncDaysBack` days after it started.
///
/// Fix: both call sites now pass `predicate: nil`. The bounded,
/// explicitly-scoped historical window (`fetchOneChunkNewestFirst`,
/// used only by the first-time full export and the existing,
/// manually-triggered historical rescan pilot) is UNCHANGED and remains
/// bounded by design — this fix narrows what changed, it does not widen
/// historical import anywhere.
///
/// Test-coverage honesty, matching this suite's own established
/// precedent (see SyncProgressTracingTests.swift's own header): neither
/// changed call site can be exercised end-to-end here. Both call
/// `healthStore.execute(query:)` against a non-overridable
/// `let healthStore = HKHealthStore()` (OpenWearablesHealthSDK.swift),
/// and this suite has no HealthKit test double for the query/anchor
/// semantics themselves — introducing one would be a materially larger
/// refactor than this fix, and the prior WP explicitly declined exactly
/// that tradeoff for a smaller change. The tests below are therefore
/// STRUCTURAL (verified against the real compiled source text) for the
/// predicate change itself, plus ordinary behavioral tests for the one
/// piece of this change that IS fully exercisable without HealthKit:
/// `syncStartDate()`'s own pure date math, already covered by
/// OpenWearablesHealthSDKTests.swift and re-confirmed unchanged here.
/// Real-device or simulator validation of the actual HealthKit query
/// behavior (does an anchor genuinely surface an old-dated sample after
/// this change) has NOT been performed as part of this gate and remains
/// an explicit, named gap in the completion report.
final class DurationIndependentDiscoveryTests: XCTestCase {

    private static let sdkSourceURL: URL = {
        // This test file's own location: Tests/OpenWearablesHealthSDKTests/.
        // The main source lives at Sources/OpenWearablesHealthSDK/OpenWearablesHealthSDK.swift,
        // a fixed, known relative path from here.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // OpenWearablesHealthSDKTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Sources/OpenWearablesHealthSDK/OpenWearablesHealthSDK.swift")
    }()

    private func loadSource() throws -> String {
        try String(contentsOf: Self.sdkSourceURL, encoding: .utf8)
    }

    /// Strips `//` line comments and `/* */` block comments before any
    /// `.contains()` check below — this file's OWN explanatory comments
    /// (including the ones added alongside this very fix) deliberately
    /// name "syncStartDate()" and "predicateForSamples" in prose, which a
    /// plain substring search over raw source would misfire on. Code
    /// only, same fix as every other "assert the source no longer does
    /// X" test written during this investigation.
    private func codeOnly(_ text: String) -> String {
        let noBlockComments = text.replacingOccurrences(
            of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression
        )
        return noBlockComments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let range = line.range(of: "//") {
                    return String(line[line.startIndex..<range.lowerBound])
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// Isolates one function's own body as plain text, from its `func` line
    /// up to (but not including) the next top-level `private func`/`public func`/
    /// `internal func` at the same indentation — good enough for this file's
    /// own consistent 4-space-indented style, without needing a real parser.
    private func functionBody(named name: String, in source: String) -> String? {
        guard let startRange = source.range(of: "func \(name)(") else { return nil }
        let afterStart = source[startRange.lowerBound...]
        // Find the next sibling function declaration after this one.
        let searchFrom = source.index(startRange.lowerBound, offsetBy: 1)
        let rest = source[searchFrom...]
        let nextFuncMarkers = ["\n    private func ", "\n    public func ", "\n    internal func "]
        var earliestNext: String.Index? = nil
        for marker in nextFuncMarkers {
            if let r = rest.range(of: marker) {
                if earliestNext == nil || r.lowerBound < earliestNext! {
                    earliestNext = r.lowerBound
                }
            }
        }
        if let end = earliestNext {
            return String(afterStart[afterStart.startIndex..<end])
        }
        return String(afterStart)
    }

    func testFetchOneChunkIncrementalNoLongerAppliesAStartDatePredicate() throws {
        let source = try loadSource()
        guard let rawBody = functionBody(named: "fetchOneChunkIncremental", in: source) else {
            XCTFail("fetchOneChunkIncremental not found in SDK source — has it been renamed?")
            return
        }
        let body = codeOnly(rawBody)
        XCTAssertFalse(body.contains("syncStartDate()"), "the incremental (anchor-based) fetch must never re-introduce a date-bounded predicate")
        XCTAssertFalse(body.contains("predicateForSamples"), "the incremental fetch must never build a date predicate at all")
        XCTAssertTrue(body.contains("predicate: nil"), "the incremental fetch's own HKAnchoredObjectQuery must be called with predicate: nil")
    }

    func testCaptureAnchorStepNoLongerAppliesAStartDatePredicate() throws {
        let source = try loadSource()
        guard let rawBody = functionBody(named: "captureAnchorStep", in: source) else {
            XCTFail("captureAnchorStep not found in SDK source — has it been renamed?")
            return
        }
        let body = codeOnly(rawBody)
        XCTAssertFalse(body.contains("syncStartDate()"), "the anchor-baseline capture must never re-introduce a date-bounded predicate — a bounded baseline would reintroduce the exact poisoning risk this fix exists to close")
        XCTAssertFalse(body.contains("predicateForSamples"))
        XCTAssertTrue(body.contains("predicate: nil"))
    }

    /// The bounded historical path must remain exactly as bounded as
    /// before — this fix narrows the incremental path only. A regression
    /// here (removing the bound from full export) would silently
    /// introduce the "automatic unlimited historical import" this WP was
    /// explicitly told not to build.
    func testFetchOneChunkNewestFirstStillAppliesTheHistoricalBound() throws {
        let source = try loadSource()
        guard let rawBody = functionBody(named: "fetchOneChunkNewestFirst", in: source) else {
            XCTFail("fetchOneChunkNewestFirst not found in SDK source — has it been renamed?")
            return
        }
        let body = codeOnly(rawBody)
        XCTAssertTrue(body.contains("syncStartDate()"), "the explicit, bounded full-export/historical fetch must remain bounded by syncDaysBack — unchanged by this fix")
    }

    /// Re-confirms syncStartDate() itself is untouched by this change —
    /// it is still the pure date-math function the (unchanged, still
    /// bounded) historical path depends on; only its CALLERS in the
    /// incremental path were changed to stop using it.
    func testSyncStartDateMathUnchanged() {
        let sdk = OpenWearablesHealthSDK.shared
        sdk.setSyncDaysBack(7)
        let sevenDayStart = sdk.syncStartDate()
        XCTAssertNotNil(sevenDayStart)

        sdk.setSyncDaysBack(0)
        XCTAssertNil(sdk.syncStartDate(), "syncDaysBack of 0 must still mean \"no bound\" (full sync), exactly as before this change")
    }
}
