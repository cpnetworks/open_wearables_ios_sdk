import Foundation

/// Map Roadmap #27 Stage F - bounded real-device retry proof ONLY.
///
/// Reproducing the HealthKit route-availability race (RouteRetry.swift's
/// own header) naturally requires waiting on HealthKit's own write timing,
/// which is not something a proof can schedule. This file lets the host
/// app arm exactly one forced miss ahead of a real recording, so the
/// REAL Stage F retry mechanism - the unmodified code in RouteRetry.swift,
/// querying real HealthKit - can be exercised deterministically instead
/// of by chance.
///
/// Entirely `#if DEBUG`: this file compiles to nothing in a Release
/// build - there is no runtime flag to disable, because the symbol does
/// not exist. `nm`/`strings` on a Release binary will not find
/// `armForcedRouteFetchMiss` or `forcedRouteMissAfterForDebugProof`.
#if DEBUG
extension OpenWearablesHealthSDK {

    /// Arms a ONE-TIME forced miss for the next workout HealthKit delivers
    /// whose `startDate` is at or after `date` (default: now). The very
    /// first `fetchRoutePayload` call matching that workout reports a
    /// miss - same as a genuine HealthKit timing miss - and the arming
    /// clears itself immediately, so:
    /// - the workout's own upload proceeds normally this round (no route
    ///   attached, exactly as a real miss would produce);
    /// - its anchor advances exactly as normal - nothing here touches
    ///   anchor logic at all;
    /// - the real `recordPendingRouteRetryIfNeeded` creates the real
    ///   pending-retry entry, the same way a genuine miss does;
    /// - every subsequent call - including this same workout's own
    ///   later retry via `retryPendingRoutesIfPossible` - runs the real,
    ///   unmodified `fetchRoutePayload` query against real HealthKit.
    ///
    /// Call this BEFORE recording the proof activity (there is no
    /// reliable way to win a race against HealthKit's own observer
    /// delivery once the workout already exists) and only ever for one
    /// proof run at a time - arming again before the first arming has
    /// matched replaces it, it does not stack.
    public func armForcedRouteFetchMiss(forWorkoutsStartingAfter date: Date = Date()) {
        forcedRouteMissAfterForDebugProof = date
        logMessage("DEBUG: armed forced route fetch miss for workouts starting after \(date) (Stage F proof)")
    }

    /// Disarms without waiting for a match - proof cleanup / safety net.
    public func disarmForcedRouteFetchMiss() {
        forcedRouteMissAfterForDebugProof = nil
    }
}
#endif
