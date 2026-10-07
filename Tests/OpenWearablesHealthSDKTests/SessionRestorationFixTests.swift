import XCTest
import HealthKit
@testable import OpenWearablesHealthSDK

/// OW Session Restoration Fix WP (2026-10-07) — SDK-level proof for the two
/// branches Sole Mates' app-side bootstrap decision
/// (HealthSyncViewModel.decideBootstrapAction, in the main app, not this
/// package) chooses between on every cold launch / silent session restore:
///
///   - same-user restoration → updateTokens(accessToken:refreshToken:)
///   - new identity (first sign-in or account switch) → signIn(...)
///
/// These tests verify the REAL vendored SDK's own documented behavior for
/// each branch against the actual on-disk/UserDefaults/Keychain state it
/// manages — not a mock. They are the evidence that choosing updateTokens
/// over signIn actually preserves HealthKit anchors, full-export progress,
/// in-progress sync state and the outbox, and that signIn still correctly
/// wipes all four when establishing a genuinely new identity (unchanged,
/// pre-existing, intentional behavior — re-verified here as a regression
/// guard for the fix's own assumptions).
///
/// Scope note: this does NOT execute
/// HealthSyncViewModel.bootstrapOpenWearablesAndHealthKit or
/// decideBootstrapAction itself — the Sole Mates app has no Xcode test
/// target, and no xcodeproj/xcodegen/tuist is available on this machine to
/// add one safely. decideBootstrapAction's pure identity-matching logic is
/// instead verified here as a literal, clearly-labeled copy (see
/// testDecideBootstrapActionTruthTable below) — the real app file and this
/// copy must be kept in sync by inspection; they are small and unlikely to
/// drift silently, but this is a known gap, not a hidden one.
final class SessionRestorationFixTests: XCTestCase {

    private let userA = "session-fix-test-user-a"
    private let userB = "session-fix-test-user-b"
    private let workoutType = HKObjectType.workoutType()

    override func setUp() {
        super.setUp()
        // Keychain.swift's own "Test Seam" doc comment: an XCTest bundle has
        // no keychain access group, so real SecItemAdd calls fail silently
        // (-34018) without this. Isolates these tests from whatever may be
        // in the real device/simulator Keychain.
        OpenWearablesHealthSdkKeychain.volatileStore = [:]
    }

    override func tearDown() {
        let sdk = OpenWearablesHealthSDK.shared
        sdk.clearSyncSession()
        sdk.clearOutbox()
        // Anchors/fullDone are keyed by the SDK's current in-memory userId
        // (read from Keychain at call time, see Anchors.swift's userKey()),
        // so clean up each test identity this file used by impersonating it
        // briefly, purely to compute and clear its own keys.
        for uid in [userA, userB] {
            OpenWearablesHealthSdkKeychain.volatileStore?["userId"] = uid
            sdk.resetAllAnchors()
        }
        OpenWearablesHealthSdkKeychain.volatileStore = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func seedEstablishedSession(userId: String, sdk: OpenWearablesHealthSDK) {
        sdk.signIn(userId: userId, accessToken: "initial-access-\(userId)", refreshToken: "initial-refresh-\(userId)", apiKey: nil)

        // resetAllAnchors() only clears keys for types in trackedTypes (see
        // Anchors.swift) — normally populated by requestAuthorization(types:)
        // or restored by configure(), neither of which this unit test drives
        // (both touch real HealthKit/Keychain state beyond what's needed
        // here). Set directly so the anchor saved below is actually in
        // scope for a reset, matching what a real signed-in session has.
        sdk.trackedTypes = [workoutType]

        // HealthKit anchor + full-export flag, as a real completed-type
        // round would leave them.
        let anchor = HKQueryAnchor(fromValue: 42)
        sdk.saveAnchor(anchor, for: workoutType)
        sdk.defaults.set(true, forKey: sdk.fullDoneKey())

        // In-progress SyncState, as an interrupted export would leave it.
        var state = sdk.startNewSyncState(fullExport: true, types: [workoutType])
        state.typeProgress[workoutType.identifier] = TypeSyncProgress(
            typeIdentifier: workoutType.identifier, sentCount: 7, isComplete: false,
            pendingAnchorData: nil, pendingOlderThan: nil
        )
        state.totalSentCount = 7
        sdk.saveSyncState(state)

        // A leftover outbox item, as Outbox.swift's own header comment
        // describes (pre-0.14 leftovers, never written by current code,
        // but still present on some devices and must survive a token
        // refresh exactly like anchors/sync state do).
        try? FileManager.default.createDirectory(at: sdk.outboxDir(), withIntermediateDirectories: true)
        let leftoverItem = sdk.outboxDir().appendingPathComponent("item_leftover.json")
        try? Data("{}".utf8).write(to: leftoverItem)
    }

    // MARK: - Same-user restoration → updateTokens must preserve everything

    func testUpdateTokensPreservesAnchorFullDoneSyncStateAndOutboxForSameUser() {
        let sdk = OpenWearablesHealthSDK.shared
        seedEstablishedSession(userId: userA, sdk: sdk)
        XCTAssertNotNil(sdk.loadAnchor(for: workoutType), "fixture setup should have an anchor")
        XCTAssertTrue(sdk.defaults.bool(forKey: sdk.fullDoneKey()))
        XCTAssertNotNil(sdk.loadSyncState())
        let outboxFilesBefore = (try? FileManager.default.contentsOfDirectory(at: sdk.outboxDir(), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(outboxFilesBefore.count, 1, "fixture setup should have one leftover outbox item")

        sdk.updateTokens(accessToken: "refreshed-access", refreshToken: "refreshed-refresh")

        XCTAssertNotNil(sdk.loadAnchor(for: workoutType), "updateTokens must not reset HealthKit anchors")
        XCTAssertTrue(sdk.defaults.bool(forKey: sdk.fullDoneKey()), "updateTokens must not clear full-export progress")
        let state = sdk.loadSyncState()
        XCTAssertNotNil(state, "updateTokens must not clear in-progress sync state")
        XCTAssertEqual(state?.totalSentCount, 7)
        XCTAssertEqual(state?.typeProgress[workoutType.identifier]?.sentCount, 7)
        let outboxFilesAfter = (try? FileManager.default.contentsOfDirectory(at: sdk.outboxDir(), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(outboxFilesAfter.count, 1, "updateTokens must not clear the outbox")
    }

    func testUpdateTokensActuallyWritesTheNewTokensAndKeepsSameUserId() {
        let sdk = OpenWearablesHealthSDK.shared
        seedEstablishedSession(userId: userA, sdk: sdk)

        sdk.updateTokens(accessToken: "refreshed-access", refreshToken: "refreshed-refresh")

        let creds = sdk.getStoredCredentials()
        XCTAssertEqual(creds["userId"] as? String, userA, "same-user restoration must not change the stored identity")
        XCTAssertEqual(OpenWearablesHealthSdkKeychain.getAccessToken(), "refreshed-access")
        XCTAssertEqual(OpenWearablesHealthSdkKeychain.getRefreshToken(), "refreshed-refresh")
        XCTAssertTrue(sdk.isSessionValid)
    }

    // MARK: - New identity → signIn must still fully reset (regression guard)

    func testSignInForDifferentUserWipesAnchorFullDoneSyncStateAndOutboxOfPreviousUser() {
        let sdk = OpenWearablesHealthSDK.shared
        seedEstablishedSession(userId: userA, sdk: sdk)

        sdk.signIn(userId: userB, accessToken: "access-b", refreshToken: "refresh-b", apiKey: nil)

        // userId is now B, so loadAnchor/fullDoneKey for A's old data are
        // unreachable under A's key, and B's own fresh key is clean.
        OpenWearablesHealthSdkKeychain.volatileStore?["userId"] = userA
        XCTAssertNil(sdk.loadAnchor(for: workoutType), "switching identity must wipe the previous user's anchors")
        XCTAssertFalse(sdk.defaults.bool(forKey: sdk.fullDoneKey()), "switching identity must clear the previous user's full-export flag")
        OpenWearablesHealthSdkKeychain.volatileStore?["userId"] = userB

        XCTAssertNil(sdk.loadSyncState(), "switching identity must clear in-progress sync state")
        let outboxFilesAfter = (try? FileManager.default.contentsOfDirectory(at: sdk.outboxDir(), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(outboxFilesAfter.count, 0, "switching identity must clear the outbox")
        XCTAssertEqual(sdk.getStoredCredentials()["userId"] as? String, userB)
    }

    func testFirstEverSignInStartsFromCleanStateWithNoResumableSession() {
        let sdk = OpenWearablesHealthSDK.shared
        XCTAssertNil(sdk.getStoredCredentials()["userId"] as? String, "fixture should start with no prior identity")

        sdk.signIn(userId: userA, accessToken: "access-a", refreshToken: "refresh-a", apiKey: nil)

        XCTAssertEqual(sdk.getStoredCredentials()["userId"] as? String, userA)
        XCTAssertTrue(sdk.isSessionValid)
        XCTAssertFalse(sdk.hasResumableSyncSession())
        XCTAssertFalse(sdk.defaults.bool(forKey: sdk.fullDoneKey()))
    }

    // MARK: - Explicit sign-out clears identity, so the next bootstrap signs in fresh

    func testAfterSignOutStoredUserIdIsClearedSoFreshUserIdNeverMatches() {
        let sdk = OpenWearablesHealthSDK.shared
        seedEstablishedSession(userId: userA, sdk: sdk)

        sdk.signOut()

        let storedUserId = sdk.getStoredCredentials()["userId"] as? String
        XCTAssertNil(storedUserId, "signOut must clear the stored identity")
        // Mirrors decideBootstrapAction's own branch: a nil stored userId
        // can never equal a fresh userId, however it compares, so the next
        // bootstrap always takes the signIn (new session) branch.
        XCTAssertEqual(
            HealthSyncViewModelDecisionMirror.decideBootstrapAction(storedUserId: storedUserId, freshUserId: userA),
            .signInAsNewSession
        )
    }

    // MARK: - Pure decision logic (app-side, mirrored here — see file header)

    /// Literal copy of HealthSyncViewModel's nested
    /// `decideBootstrapAction`/`OWSessionBootstrapAction` — see this file's
    /// header for why a copy, not an import, is used. Keep in sync with
    /// ios/SoleMatesiOS/Sole Mates/Sole Mates/HealthSyncViewModel.swift by
    /// inspection if either changes.
    private enum HealthSyncViewModelDecisionMirror {
        enum Action: Equatable {
            case updateTokensForExistingSession
            case signInAsNewSession
        }
        static func decideBootstrapAction(storedUserId: String?, freshUserId: String) -> Action {
            if let storedUserId, storedUserId == freshUserId {
                return .updateTokensForExistingSession
            }
            return .signInAsNewSession
        }
    }

    func testDecideBootstrapActionTruthTable() {
        typealias M = HealthSyncViewModelDecisionMirror
        // Same-user cold launch / token expiry+refresh: same non-nil id.
        XCTAssertEqual(M.decideBootstrapAction(storedUserId: "u1", freshUserId: "u1"), .updateTokensForExistingSession)
        // First-ever sign-in: nothing stored yet.
        XCTAssertEqual(M.decideBootstrapAction(storedUserId: nil, freshUserId: "u1"), .signInAsNewSession)
        // Account switch: stored identity differs from the fresh one.
        XCTAssertEqual(M.decideBootstrapAction(storedUserId: "u1", freshUserId: "u2"), .signInAsNewSession)
        // Defensive: empty-string stored id must not accidentally equal a
        // real one by some other coincidental comparison path.
        XCTAssertEqual(M.decideBootstrapAction(storedUserId: "", freshUserId: "u1"), .signInAsNewSession)
    }
}
