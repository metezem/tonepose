import Foundation

@Observable
@MainActor
final class UserSettings {
    private let semitonesMapKey = "toneposeSemitonesByBundleID"
    private let targetKey = "toneposeTargetBundleID"
    private let pinnedKey = "toneposePinnedBundleIDs"
    private let legacySemitonesKey = "transposeSemitones"
    /// Pre–tonepose key names (migrate once)
    private let oldSemitonesMapKey = "transposeSemitonesByBundleID"
    private let oldTargetKey = "transposeTargetBundleID"
    private let oldPinnedKey = "transposePinnedBundleIDs"

    /// Per–bundle-ID transpose amount (−12 … 12 semitones).
    var semitonesByBundleID: [String: Float] {
        didSet {
            persistSemitonesMap()
        }
    }

    /// Bundle ID of the app whose audio is tapped (e.g. `com.spotify.client`).
    var targetBundleID: String {
        didSet {
            UserDefaults.standard.set(targetBundleID, forKey: targetKey)
        }
    }

    /// Semitones for the currently selected target (stored under `targetBundleID`).
    var semitoneOffset: Float {
        get { normalizedSemitone(semitonesByBundleID[targetBundleID]) }
        set {
            let v = normalizedSemitone(newValue)
            var m = semitonesByBundleID
            m[targetBundleID] = v
            semitonesByBundleID = m
        }
    }

    /// User-pinned bundle IDs (shown in the quick list when that app is running / visible to Core Audio).
    var pinnedBundleIDs: [String] {
        didSet {
            UserDefaults.standard.set(pinnedBundleIDs, forKey: pinnedKey)
        }
    }

    func pinBundleID(_ bundleID: String) {
        guard !bundleID.isEmpty, !pinnedBundleIDs.contains(bundleID) else { return }
        pinnedBundleIDs = pinnedBundleIDs + [bundleID]
    }

    func unpinBundleID(_ bundleID: String) {
        pinnedBundleIDs = pinnedBundleIDs.filter { $0 != bundleID }
    }

    init() {
        let initialTarget: String
        if let s = UserDefaults.standard.string(forKey: targetKey), !s.isEmpty {
            initialTarget = s
        } else if let s = UserDefaults.standard.string(forKey: oldTargetKey), !s.isEmpty {
            initialTarget = s
        } else {
            initialTarget = "com.spotify.client"
        }

        let initialSemitones: [String: Float]
        if let rawMap = UserDefaults.standard.dictionary(forKey: semitonesMapKey) as? [String: Double] {
            initialSemitones = Self.parseSemitoneMap(rawMap)
        } else if let rawMap = UserDefaults.standard.dictionary(forKey: oldSemitonesMapKey) as? [String: Double] {
            initialSemitones = Self.parseSemitoneMap(rawMap)
        } else if let legacy = UserDefaults.standard.object(forKey: legacySemitonesKey) as? Double {
            let v = Self.normalizedSemitoneStatic(Float(legacy))
            initialSemitones = [initialTarget: v]
            UserDefaults.standard.removeObject(forKey: legacySemitonesKey)
        } else {
            initialSemitones = [:]
        }

        let initialPinned: [String]
        if let pinned = UserDefaults.standard.array(forKey: pinnedKey) as? [String] {
            initialPinned = pinned
        } else if let pinned = UserDefaults.standard.array(forKey: oldPinnedKey) as? [String] {
            initialPinned = pinned
        } else {
            initialPinned = []
        }

        targetBundleID = initialTarget
        semitonesByBundleID = initialSemitones
        pinnedBundleIDs = initialPinned

        Self.removeLegacyKeysIfMigrated()
    }

    private static func parseSemitoneMap(_ rawMap: [String: Double]) -> [String: Float] {
        var m: [String: Float] = [:]
        for (k, d) in rawMap {
            m[k] = normalizedSemitoneStatic(Float(d))
        }
        return m
    }

    /// Drops legacy UserDefaults keys after tonepose keys are in use.
    private static func removeLegacyKeysIfMigrated() {
        let d = UserDefaults.standard
        guard d.object(forKey: "toneposeTargetBundleID") != nil else { return }
        d.removeObject(forKey: "transposeTargetBundleID")
        d.removeObject(forKey: "transposeSemitonesByBundleID")
        d.removeObject(forKey: "transposePinnedBundleIDs")
        d.removeObject(forKey: "transposeSemitones")
    }

    private func persistSemitonesMap() {
        let dict = semitonesByBundleID.mapValues { Double($0) }
        UserDefaults.standard.set(dict, forKey: semitonesMapKey)
    }

    private func normalizedSemitone(_ v: Float?) -> Float {
        Self.normalizedSemitoneStatic(v ?? 0)
    }

    private static func normalizedSemitoneStatic(_ raw: Float) -> Float {
        Float(min(12, max(-12, Int(round(Double(raw))))))
    }
}
