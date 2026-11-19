import Foundation

/// GDPR-04 (Sole Mates decision D1) — on-device data minimisation for every
/// upload. Applied to the final payload in `buildCombinedPayload`, which every
/// upload path uses (main sync loop, route retry, historical route rescan,
/// historical stats rescan), so prohibited fields never leave the phone.
///
/// Kept: workouts' id, parentId, type, start/end, zoneOffset, route points
/// (t, lat, lng, alt, segmentIndex) and the statistics in
/// `allowedWorkoutStatistics` (duration, distance, elevation gain/loss and
/// indoor / swim-location context); source app / bundle id, de-personalised
/// name and device name, device manufacturer / model / type.
/// Dropped: heart rate, power, cadence, steps, energy, speed, stride,
/// vertical oscillation, ground contact, METs, weather and every other
/// statistic; laps, segments, samples, metadata, title, notes; all `records`
/// and `sleep`; OS / hardware / software versions and device ids.
internal enum PayloadAllowlist {
    /// Set to false only for a non-Sole-Mates integration that needs the full payload.
    static var enabled = true

    static let allowedWorkoutKeys: Set<String> = ["id", "parentId", "type", "startDate", "endDate", "zoneOffset", "source", "values", "route"]
    static let allowedWorkoutStatistics: Set<String> = [
        "duration", "totalDuration", "distance", "elevationAscended", "elevationDescended",
        "altitudeGain", "altitudeLoss", "indoorWorkout", "swimmingLocationType",
    ]
    static let allowedSourceKeys: Set<String> = ["appId", "bundleIdentifier", "name", "deviceName", "deviceManufacturer", "deviceModel", "deviceType", "productType", "recordingMethod"]
    static let allowedRoutePointKeys: Set<String> = ["t", "lat", "lng", "alt", "segmentIndex"]

    private static let possessive = try? NSRegularExpression(pattern: "^[^\\s'’]+(?:\\s+[^\\s'’]+)?['’]s?\\s+(?=\\S)")
    private static let suffix = try? NSRegularExpression(pattern: "\\s+(?:von|de|di|of|van)\\s+\\S.*$", options: [.caseInsensitive])

    /// Same rule as Sole Mates `minimizeDeviceName` and the OW server-side strip.
    static func minimizeDeviceName(_ raw: Any?) -> Any {
        guard var s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return NSNull() }
        for re in [possessive, suffix].compactMap({ $0 }) {
            let range = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        s = String(s.trimmingCharacters(in: .whitespaces).prefix(64))
        return s.isEmpty ? NSNull() : s
    }

    static func minimizeSource(_ source: Any?) -> Any {
        guard let src = source as? [String: Any] else { return NSNull() }
        var out: [String: Any] = [:]
        for (k, v) in src where allowedSourceKeys.contains(k) {
            out[k] = (k == "name" || k == "deviceName") ? minimizeDeviceName(v) : v
        }
        return out
    }

    static func minimizeWorkout(_ w: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in w where allowedWorkoutKeys.contains(k) {
            switch k {
            case "source":
                out[k] = minimizeSource(v)
            case "values":
                out[k] = (v as? [[String: Any]] ?? []).filter { allowedWorkoutStatistics.contains(($0["type"] as? String) ?? "") }
            case "route":
                if let pts = v as? [[String: Any]] {
                    out[k] = pts.map { p in p.filter { allowedRoutePointKeys.contains($0.key) } }
                } else {
                    out[k] = NSNull()
                }
            default:
                out[k] = v
            }
        }
        return out
    }

    /// Pure: the minimised payload. Top-level keys (provider, sdkVersion,
    /// syncTimestamp, syncSessionId, syncType) are kept; `data` is rebuilt.
    static func apply(_ payload: [String: Any]) -> [String: Any] {
        guard enabled else { return payload }
        var out = payload
        let data = payload["data"] as? [String: Any] ?? [:]
        let workouts = (data["workouts"] as? [[String: Any]] ?? []).map(minimizeWorkout)
        out["data"] = ["workouts": workouts, "records": [[String: Any]](), "sleep": [[String: Any]]()]
        return out
    }

    /// GDPR-04 — the generic sync loop reads workouts only (the distance
    /// types stay authorisation-only), so all-day samples are never collected.
    static func isSyncableIdentifier(_ identifier: String) -> Bool {
        !enabled || identifier == "HKWorkoutTypeIdentifier"
    }
}
