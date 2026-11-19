import Foundation

/// Backup exclusion and file protection for everything the SDK keeps on disk.
///
/// The SDK's state lives under the host app's Application Support directory
/// (`stateBaseDirectory()`), which iOS includes in iCloud and Finder/iTunes
/// device backups by default. That state is derived from HealthKit (workout
/// UUIDs, sync progress, route-retry queue) and, for installs that still hold
/// pre-0.14 outbox leftovers, raw health payloads. It can always be rebuilt
/// from HealthKit, so it must not be backed up (App Review Guideline 5.1.3(ii):
/// no personal health information in iCloud).
///
/// The SDK never excludes the base directory itself: it is the host app's own
/// Application Support folder. Only the items listed in `sdkOwnedStateItemNames`
/// are touched.
///
/// - Directories carry `isExcludedFromBackup`; their contents inherit it.
/// - Files written directly into the base directory get the flag after every
///   write, because an `.atomic` write replaces the file and drops it.
/// - Everything uses `.completeUntilFirstUserAuthentication`, the strictest
///   class that still lets HealthKit background delivery and `BGTask` runs
///   (which can happen while the device is locked after the first unlock) read
///   and write the state.
extension OpenWearablesHealthSDK {

    /// Directories the SDK owns under `stateBaseDirectory()`.
    internal static let sdkOwnedStateDirectoryNames: [String] = [
        "health_sync_state",
        "health_outbox",
    ]

    /// Files the SDK writes directly into `stateBaseDirectory()`.
    internal static let sdkOwnedStateFileNames: [String] = [
        "pending_apple_route_retries.json",
        "historical_route_rescan_state.json",
        "historical_workout_stats_rescan_state.json",
    ]

    internal static var sdkOwnedStateItemNames: [String] {
        sdkOwnedStateDirectoryNames + sdkOwnedStateFileNames
    }

    internal static let stateFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    /// Idempotent. Called from `init` (every process start, including background
    /// launches) and before each state write. Creates the sync-state directory,
    /// then applies protection and backup exclusion to every SDK-owned item that
    /// exists. The legacy outbox is never created (nothing writes it since 0.14);
    /// it is only marked if it is still on disk.
    internal func prepareStateStorage() {
        let base = stateBaseDirectory()
        let fm = FileManager.default
        try? fm.createDirectory(
            at: syncStateDir(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.stateFileProtection]
        )
        for name in Self.sdkOwnedStateItemNames {
            let url = base.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            Self.protectAndExcludeFromBackup(url)
        }
    }

    /// Writes SDK state atomically with file protection, then re-applies backup
    /// exclusion (an atomic write replaces the file, so the old flag is gone).
    internal func writeStateFile(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
        Self.protectAndExcludeFromBackup(url)
    }

    @discardableResult
    internal static func protectAndExcludeFromBackup(_ url: URL) -> Bool {
        try? FileManager.default.setAttributes([.protectionKey: stateFileProtection], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    internal static func isExcludedFromBackup(_ url: URL) -> Bool {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}
