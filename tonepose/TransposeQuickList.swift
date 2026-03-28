import Foundation

/// Popular music clients + browsers; only entries present in `tapTargets` appear in the menu bar quick list.
enum TransposeQuickList {
    struct Row: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let isOnAudioGraph: Bool
    }

    private enum Catalog {
        static let bundleIDsInOrder: [String] = [
            "com.spotify.client",
            "com.apple.Music",
            "com.tidal.desktop",
            "com.amazon.music.mac",
            "com.deezer.Deezer",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.apple.Safari",
            "com.brave.Browser",
        ]

        static let bundleIDSet = Set(bundleIDsInOrder)
    }

    /// Built-in catalog apps (Spotify, Safari, …). These are never offered in “pin to add” — they appear on the quick list automatically when running.
    static var catalogBundleIDs: Set<String> { Catalog.bundleIDSet }

    /// Catalog order for popular apps, then pinned-only (non-catalog) apps that are running, by name.
    static func rows(tapTargets: [TapAudioTarget], pinnedBundleIDs: [String]) -> [Row] {
        let tapByID = Dictionary(uniqueKeysWithValues: tapTargets.map { ($0.bundleID, $0) })
        let popular = Catalog.bundleIDSet
        var seen = Set<String>()
        var out: [Row] = []

        for bid in Catalog.bundleIDsInOrder {
            guard let t = tapByID[bid] else { continue }
            seen.insert(t.bundleID)
            out.append(Row(bundleID: t.bundleID, displayName: t.displayName, isOnAudioGraph: t.isOnAudioGraph))
        }

        let pinnedOnly = pinnedBundleIDs.filter { !popular.contains($0) }
        for bid in pinnedOnly.sorted(by: { a, b in
            let na = tapByID[a]?.displayName ?? a
            let nb = tapByID[b]?.displayName ?? b
            return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending
        }) {
            guard let t = tapByID[bid], !seen.contains(bid) else { continue }
            seen.insert(bid)
            out.append(Row(bundleID: t.bundleID, displayName: t.displayName, isOnAudioGraph: t.isOnAudioGraph))
        }

        return out
    }
}
