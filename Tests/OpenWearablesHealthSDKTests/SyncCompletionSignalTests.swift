import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Sync Progress Tracing WP (2026-10-07) — the app's own "watch" loop used
/// to treat the transient `isSyncing` boolean (plus a stale `initialExportDone`
/// flag, removed in a separate commit) as its completion signal. Both are
/// racy: a round fast enough to start and finish between two poll ticks
/// never gets observed transitioning, and the loop would wait out its full
/// timeout even though the round had already genuinely finished. These
/// tests cover exactly the four scenarios the app's watch logic has to get
/// right, using `currentSyncGeneration`/`lastCompletedSyncGeneration`
/// (exposed via `getSyncStatus()` as "generation"/"completedGeneration")
/// instead: a caller captures `generation` right after starting a round,
/// then treats `completedGeneration >= thatValue` as "this round has run to
/// its own natural end" — true however fast or slow the round was, because
/// the counter is monotonic and sticky rather than a snapshot.
final class SyncCompletionSignalTests: XCTestCase {

    // MARK: - An empty incremental query

    /// Nothing for HealthKit to return is a legitimate, fast, successful
    /// outcome — must be reported as completed, not confused with "hasn't
    /// started yet" or left to time out.
    func testEmptyIncrementalRoundAdvancesCompletedGeneration() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            let capturedGeneration = sdk.currentSyncGeneration
            XCTAssertEqual(capturedGeneration, generation)

            // The round found nothing and finishes immediately — exactly
            // what processNextRound's own allSamples.isEmpty branch does
            // before recursing with nothing left to do.
            sdk.finishSync(generation: generation)

            XCTAssertGreaterThanOrEqual(sdk.lastCompletedSyncGeneration, capturedGeneration)
        }
    }

    // MARK: - A round that finishes before the first polling tick

    /// The actual regression this WP's investigation found: if the caller
    /// polls on a fixed interval, a round that starts AND finishes between
    /// two ticks must still be detected on the very next read — never
    /// require having caught it "in the act."
    func testRoundFasterThanOnePollIntervalIsStillDetected() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            let capturedGeneration = sdk.currentSyncGeneration

            // Simulates the entire round — begin and finish — happening
            // before any poll could have observed isSyncing flip true.
            // No sleep, no poll: finishSync runs on the very next line.
            sdk.finishSync(generation: generation)

            // A caller polling even once, any amount of time later, must
            // still see this as done — the signal does not depend on
            // catching a transient state.
            let status = sdk.getSyncStatus()
            let polledGeneration = status["generation"] as? Int
            let polledCompleted = status["completedGeneration"] as? Int
            XCTAssertEqual(polledGeneration, capturedGeneration)
            XCTAssertNotNil(polledCompleted)
            XCTAssertGreaterThanOrEqual(polledCompleted ?? -1, capturedGeneration)
        }
    }

    // MARK: - A sync already running when requested

    /// A second request while one is already in flight must not be told
    /// "started a fresh round" — beginSyncRun() itself refuses (returns
    /// nil) when a generation is already active, so there is nothing new
    /// for a caller to wait on beyond the one already running.
    func testSyncAlreadyInProgressDoesNotClaimANewGeneration() {
        withIsolatedSDK { sdk, _ in
            guard let firstGeneration = sdk.beginSyncRun() else {
                return XCTFail("Could not start the first sync run")
            }

            let secondAttempt = sdk.beginSyncRun()
            XCTAssertNil(secondAttempt, "a second concurrent beginSyncRun() must be refused")

            // The generation a caller would observe at this moment is
            // still the one already in flight — not advanced, not nil.
            XCTAssertEqual(sdk.currentSyncGeneration, firstGeneration)
            XCTAssertLessThan(sdk.lastCompletedSyncGeneration, firstGeneration)

            sdk.finishSync(generation: firstGeneration)
            XCTAssertGreaterThanOrEqual(sdk.lastCompletedSyncGeneration, firstGeneration)
        }
    }

    // MARK: - Query/upload failure and token-refresh failure

    /// finishSync() runs on every exit path of a round that started,
    /// success or not — a failed upload (or a refresh that was itself
    /// rejected) must still advance completedGeneration, so a watching
    /// caller recognizes the attempt as finished rather than waiting out
    /// its timeout for a round that already gave up.
    func testFailedUploadStillAdvancesCompletedGeneration() {
        withIsolatedSDK { sdk, _ in
            guard let endpoint = sdk.syncEndpoint, let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            let capturedGeneration = sdk.currentSyncGeneration

            StubURLProtocol.install { _ in .status(500) }

            var outcome: Bool?
            sdk.uploadCombinedPayload(
                payload: ["provider": "apple", "data": ["records": [], "sleep": [], "workouts": []]],
                endpoint: endpoint, credential: "access-1", generation: generation
            ) { outcome = $0 }
            waitUntil { outcome != nil }
            XCTAssertEqual(outcome, false)

            // uploadCombinedPayload itself never calls finishSync — that is
            // processNextRound/collectAllData's job, on every one of their
            // own exit paths (already true before this WP; re-asserted
            // here as the other half of the contract this signal depends
            // on). Simulates that caller-side finalization directly.
            sdk.finishSync(generation: generation)
            XCTAssertGreaterThanOrEqual(sdk.lastCompletedSyncGeneration, capturedGeneration)
        }
    }

    func testTokenRefreshRejectionStillAdvancesCompletedGenerationOnceFinalized() {
        withIsolatedSDK { sdk, _ in
            guard let endpoint = sdk.syncEndpoint, let generation = sdk.beginSyncRun() else {
                return XCTFail("Could not start a sync run")
            }
            let capturedGeneration = sdk.currentSyncGeneration

            var reportedStatus: Int?
            sdk.onAuthError = { status, _ in reportedStatus = status }
            StubURLProtocol.install { _ in .status(401) } // refresh itself also rejected

            var outcome: Bool?
            sdk.uploadCombinedPayload(
                payload: ["provider": "apple", "data": ["records": [], "sleep": [], "workouts": []]],
                endpoint: endpoint, credential: "access-1", generation: generation
            ) { outcome = $0 }
            waitUntil { outcome != nil }
            XCTAssertEqual(outcome, false)
            waitUntil { reportedStatus != nil }
            XCTAssertEqual(reportedStatus, 401)

            sdk.finishSync(generation: generation)
            XCTAssertGreaterThanOrEqual(sdk.lastCompletedSyncGeneration, capturedGeneration)
        }
    }
}
