import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// SDK state must stay out of iCloud / Finder device backups (StateStorage.swift).
final class StateStorageBackupExclusionTests: XCTestCase {

    /// `init` runs `prepareStateStorage()` against the real (non-overridden) base
    /// directory, so after the singleton exists the sync-state directory is there
    /// and excluded. Read-only check: nothing in the host's directory is changed.
    func testSyncStateDirectoryIsExcludedFromBackupAfterInit() {
        let sdk = OpenWearablesHealthSDK.shared
        XCTAssertNil(sdk.stateDirectoryOverride, "precondition: production base directory")
        let dir = sdk.syncStateDir()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(dir))
    }

    func testPrepareCreatesAndExcludesSyncStateDirectoryWithoutCreatingOutbox() {
        withIsolatedSDK { sdk, base in
            sdk.prepareStateStorage()
            let dir = base.appendingPathComponent("health_sync_state", isDirectory: true)
            XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(dir))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sdk.outboxDir().path),
                           "the legacy outbox must not be re-created")
            XCTAssertFalse(OpenWearablesHealthSDK.isExcludedFromBackup(base),
                           "the host app's own base directory must not be excluded")
        }
    }

    func testExistingLegacyOutboxIsExcluded() {
        withIsolatedSDK { sdk, _ in
            try? FileManager.default.createDirectory(at: sdk.outboxDir(), withIntermediateDirectories: true)
            XCTAssertFalse(OpenWearablesHealthSDK.isExcludedFromBackup(sdk.outboxDir()))
            sdk.prepareStateStorage()
            XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(sdk.outboxDir()))
        }
    }

    func testExclusionSurvivesDirectoryRecreation() {
        withIsolatedSDK { sdk, _ in
            sdk.prepareStateStorage()
            try? FileManager.default.removeItem(at: sdk.syncStateDir())
            sdk.saveSyncState(sdk.startNewSyncState(fullExport: true, types: [HKObjectType.workoutType()]))
            XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(sdk.syncStateDir()))
            XCTAssertNotNil(sdk.loadSyncState())
        }
    }

    func testPrepareIsIdempotent() {
        withIsolatedSDK { sdk, _ in
            sdk.prepareStateStorage()
            sdk.prepareStateStorage()
            XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(sdk.syncStateDir()))
        }
    }

    /// An `.atomic` write replaces the file, which drops the flag; `writeStateFile`
    /// must re-apply it on every write.
    func testRootStateFileStaysExcludedAcrossAtomicRewrites() {
        withIsolatedSDK { sdk, base in
            let url = base.appendingPathComponent("pending_apple_route_retries.json")
            sdk.writeStateFile(Data("[]".utf8), to: url)
            XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(url))
            sdk.writeStateFile(Data("[ ]".utf8), to: url)
            XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(url))
            XCTAssertEqual(try? Data(contentsOf: url), Data("[ ]".utf8))
        }
    }

    func testExistingRootStateFilesAreExcludedOnPrepare() {
        withIsolatedSDK { sdk, base in
            for name in OpenWearablesHealthSDK.sdkOwnedStateFileNames {
                let url = base.appendingPathComponent(name)
                try? Data("{}".utf8).write(to: url)
                XCTAssertFalse(OpenWearablesHealthSDK.isExcludedFromBackup(url))
            }
            sdk.prepareStateStorage()
            for name in OpenWearablesHealthSDK.sdkOwnedStateFileNames {
                XCTAssertTrue(OpenWearablesHealthSDK.isExcludedFromBackup(base.appendingPathComponent(name)), name)
            }
        }
    }

    /// The simulator does not always report a protection class; when it does,
    /// it must be the expected one.
    func testWrittenStateFileCarriesExpectedProtectionWhenReported() {
        withIsolatedSDK { sdk, base in
            let url = base.appendingPathComponent("historical_route_rescan_state.json")
            sdk.writeStateFile(Data("{}".utf8), to: url)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attrs?[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
            }
        }
    }

    func testPrivacyManifestIsBundledAndDeclaresRequiredReasons() throws {
        let bundles = Bundle.allBundles + Bundle.allFrameworks
        let url = bundles.lazy.compactMap { b -> URL? in
            if let u = b.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
               b.bundlePath.contains("OpenWearablesHealthSDK") { return u }
            if let resURL = b.resourceURL {
                let candidate = resURL.appendingPathComponent("OpenWearablesHealthSDK_OpenWearablesHealthSDK.bundle/PrivacyInfo.xcprivacy")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }.first
        let manifestURL = try XCTUnwrap(url, "SDK resource bundle with PrivacyInfo.xcprivacy not found")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: manifestURL) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let api = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: api.map {
            ($0["NSPrivacyAccessedAPIType"] as? String ?? "", $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        })
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
        let types = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertEqual(Set(types), [
            "NSPrivacyCollectedDataTypeHealth", "NSPrivacyCollectedDataTypeFitness",
            "NSPrivacyCollectedDataTypePreciseLocation", "NSPrivacyCollectedDataTypeOtherDiagnosticData",
        ])
    }
}
