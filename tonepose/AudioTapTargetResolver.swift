import AppKit
import AudioToolbox
import Darwin
import Foundation

/// One app the user can choose to tap (by bundle ID).
struct TapAudioTarget: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    /// Short display name (localized app name when available).
    let displayName: String
    /// True when Core Audio currently lists this bundle in the process object list (tap is possible).
    let isOnAudioGraph: Bool
}

/// Maps Core Audio process objects to bundle IDs and resolves tap targets for `CATapDescription`.
enum AudioTapTargetResolver {
    private static var ourBundleID: String { Bundle.main.bundleIdentifier ?? "" }

    /// Running GUI apps plus any extra bundles seen in Core Audio’s process list (e.g. helpers).
    static func enumerateTargets() -> [TapAudioTarget] {
        var map: [String: (name: String, onGraph: Bool)] = [:]

        let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })

        if let processIDs = try? AudioObjectID.readProcessList() {
            let myPID = ProcessInfo.processInfo.processIdentifier
            for objectID in processIDs {
                guard let pid = try? objectID.readProcessPID(), pid != myPID else { continue }
                guard objectID.readProcessIsRunning() else { continue }

                let direct = running[pid]
                let isApp = direct?.bundleURL?.pathExtension == "app"
                let app = isApp ? direct : findResponsibleApp(for: pid, in: running)
                let resolved = app?.bundleIdentifier ?? objectID.readProcessBundleID()
                guard let bundleID = resolved, !bundleID.isEmpty, bundleID != ourBundleID else { continue }

                let name = displayName(bundleID: bundleID, runningApp: app ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)
                if let existing = map[bundleID] {
                    map[bundleID] = (name: existing.name, onGraph: true)
                } else {
                    map[bundleID] = (name, onGraph: true)
                }
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            guard app.bundleURL?.pathExtension == "app",
                  let bid = app.bundleIdentifier,
                  !bid.isEmpty,
                  bid != ourBundleID
            else { continue }
            if map[bid] == nil {
                map[bid] = (name: app.localizedName ?? bid, onGraph: false)
            }
        }

        return map.map { key, value in
            TapAudioTarget(bundleID: key, displayName: value.name, isOnAudioGraph: value.onGraph)
        }
        .sorted {
            if $0.isOnAudioGraph != $1.isOnAudioGraph { return $0.isOnAudioGraph && !$1.isOnAudioGraph }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// All `AudioObjectID`s for `bundleID` (needed for `CATapDescription`).
    static func processObjectIDs(bundleID: String) throws -> [AudioObjectID] {
        let processIDs = try AudioObjectID.readProcessList()
        let running = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        let myPID = ProcessInfo.processInfo.processIdentifier

        var matches: [AudioObjectID] = []

        for objectID in processIDs {
            guard let pid = try? objectID.readProcessPID(), pid != myPID else { continue }
            guard objectID.readProcessIsRunning() else { continue }

            let direct = running[pid]
            let isApp = direct?.bundleURL?.pathExtension == "app"
            let app = isApp ? direct : findResponsibleApp(for: pid, in: running)
            let resolvedBundle = app?.bundleIdentifier ?? objectID.readProcessBundleID()
            guard resolvedBundle == bundleID else { continue }

            matches.append(objectID)
        }

        guard !matches.isEmpty else {
            throw NSError(
                domain: "tonepose",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "That app isn’t in the audio process list yet. Start playback there, then try again (or pick Refresh by reopening the menu)."
                ]
            )
        }

        return matches.sorted(by: <)
    }

    private static func displayName(bundleID: String, runningApp: NSRunningApplication?) -> String {
        if let n = runningApp?.localizedName, !n.isEmpty { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.localizedInfoDictionary?["CFBundleName"] as? String ?? Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
        {
            return name
        }
        return bundleID
    }

    private static func findResponsibleApp(for pid: pid_t, in running: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, !seen.contains(current) {
            seen.insert(current)
            if let app = running[current], app.bundleURL?.pathExtension == "app" { return app }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let ppid = info.kp_eproc.e_ppid
            if ppid == current { break }
            current = ppid
        }
        return nil
    }
}
