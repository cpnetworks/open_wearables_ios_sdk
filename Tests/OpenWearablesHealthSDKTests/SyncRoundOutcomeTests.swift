import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// Sync Progress Tracing WP (2026-10-07) — `completedGeneration` (added
/// earlier in this WP) only ever says a round TERMINATED, never why. A
/// confirmed gap, caught before further device testing: the host app's
/// watcher treated every termination as "Sync completed," including a
/// query error, an upload failure, or a rejected token refresh. These
/// tests cover `finishSync`'s new `outcome` parameter and the
/// `lastSyncOutcome`/`"lastOutcome"` it exposes — the signal the app now
/// has to key its "completed" claim on instead.
final class SyncRoundOutcomeTests: XCTestCase {

    // MARK: - Each outcome is stored and read back correctly, paired with its generation

    func testSuccessOutcomeIsTheDefault() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
            sdk.finishSync(generation: generation) // no outcome passed — defaults to .success
            XCTAssertEqual(sdk.lastSyncOutcome, .success)
            XCTAssertEqual(sdk.getSyncStatus()["lastOutcome"] as? String, "success")
        }
    }

    func testIncompleteWillResumeOutcome() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
            sdk.finishSync(generation: generation, outcome: .incompleteWillResume)
            XCTAssertEqual(sdk.lastSyncOutcome, .incompleteWillResume)
            XCTAssertEqual(sdk.getSyncStatus()["lastOutcome"] as? String, "incompleteWillResume")
        }
    }

    func testFailedQueryOutcome() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
            sdk.finishSync(generation: generation, outcome: .failedQuery)
            XCTAssertEqual(sdk.lastSyncOutcome, .failedQuery)
            XCTAssertEqual(sdk.getSyncStatus()["lastOutcome"] as? String, "failedQuery")
        }
    }

    func testFailedUploadOutcome() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
            sdk.finishSync(generation: generation, outcome: .failedUpload)
            XCTAssertEqual(sdk.lastSyncOutcome, .failedUpload)
            XCTAssertEqual(sdk.getSyncStatus()["lastOutcome"] as? String, "failedUpload")
        }
    }

    func testFailedAuthOutcome() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
            sdk.finishSync(generation: generation, outcome: .failedAuth)
            XCTAssertEqual(sdk.lastSyncOutcome, .failedAuth)
            XCTAssertEqual(sdk.getSyncStatus()["lastOutcome"] as? String, "failedAuth")
        }
    }

    // MARK: - A finishSync for a generation that is no longer current must not overwrite the stored outcome

    /// `finishSync`'s own guard (`generation == syncGeneration`) already
    /// protects `completedGeneration` from a late/stale callback — this
    /// confirms `completedOutcome` is written in that SAME guarded branch,
    /// so a stale generation number can never clobber the current round's
    /// recorded outcome either.
    func testFinishSyncForANonCurrentGenerationDoesNotOverwriteOutcome() {
        withIsolatedSDK { sdk, _ in
            guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
            sdk.finishSync(generation: generation, outcome: .failedUpload)
            XCTAssertEqual(sdk.lastSyncOutcome, .failedUpload)

            // Not the generation currently recorded — must be rejected,
            // exactly like finishSync already rejects it for
            // completedGeneration.
            sdk.finishSync(generation: generation + 1, outcome: .success)
            XCTAssertEqual(sdk.lastSyncOutcome, .failedUpload, "a non-current generation's outcome must not overwrite the current one")
        }
    }

    // MARK: - generation/completedGeneration/lastOutcome are one atomic snapshot, not three separate reads

    /// `getSyncStatusDict()` used to read `currentSyncGeneration`,
    /// `lastCompletedSyncGeneration` and `lastSyncOutcome` as three
    /// separately lock-scoped property accesses. Confirms the dict a
    /// caller actually polls always pairs the SAME completedGeneration
    /// with the SAME outcome, for several different outcomes in sequence
    /// — the real regression this guards is a `finishSync` for a newer
    /// generation landing between two of those reads, which a single
    /// `getSyncStatus()` call cannot observe by construction now.
    func testGenerationAndOutcomeArePairedConsistentlyAcrossMultipleRounds() {
        withIsolatedSDK { sdk, _ in
            let outcomes: [SyncRoundOutcome] = [.success, .failedQuery, .incompleteWillResume, .failedUpload, .failedAuth]
            for outcome in outcomes {
                guard let generation = sdk.beginSyncRun() else { return XCTFail("could not start") }
                sdk.finishSync(generation: generation, outcome: outcome)

                let status = sdk.getSyncStatus()
                XCTAssertEqual(status["completedGeneration"] as? Int, generation, "for outcome \(outcome)")
                XCTAssertEqual(status["lastOutcome"] as? String, outcome.rawValue, "for outcome \(outcome)")
                XCTAssertEqual(status["generation"] as? Int, generation, "for outcome \(outcome)")
            }
        }
    }

    // MARK: - A real guard path: no auth credential sets .failedAuth through collectAllData itself

    func testNoCredentialGuardReportsFailedAuthThroughRealCollectAllData() {
        withIsolatedSDK(accessToken: nil, refreshToken: nil) { sdk, _ in
            // withIsolatedSDK always saves a host; clear the credential
            // specifically so collectAllData's own "no auth credential or
            // endpoint" guard is what actually fires, not some earlier one.
            OpenWearablesHealthSdkKeychain.volatileStore?["accessToken"] = nil
            OpenWearablesHealthSdkKeychain.volatileStore?["apiKey"] = nil

            var finished = false
            sdk.collectAllData(fullExport: false) { finished = true }
            waitUntil { finished }

            XCTAssertEqual(sdk.lastSyncOutcome, .failedAuth)
        }
    }
}
