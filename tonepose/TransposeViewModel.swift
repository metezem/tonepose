import AppKit
import AudioToolbox
import Foundation
import SwiftUI

@Observable
@MainActor
final class TransposeViewModel {
    let settings = UserSettings()
    let permission = AudioCapturePermission()

    private let engine = TransposeTapEngine()

    var statusMessage: String = "Pick an app, start playback there, then the pipeline can connect."
    var isEngineRunning: Bool { engine.isRunning }
    var lastError: String?

    /// Apps from Core Audio + running `.app` bundles (for the picker).
    private(set) var tapTargets: [TapAudioTarget] = []

    /// After "Stop pipeline", polling will not reconnect until `startPipeline()`.
    private(set) var userStoppedPipeline: Bool = false

    nonisolated(unsafe) private var pollTask: Task<Void, Never>?

    init() {
        refreshTapTargets()
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { return }
                self.trySyncEngine()
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    private func refreshTapTargets() {
        var list = AudioTapTargetResolver.enumerateTargets()
        let sel = settings.targetBundleID
        if !sel.isEmpty, !list.contains(where: { $0.bundleID == sel }) {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: sel).first?.localizedName
                ?? sel.split(separator: ".").last.map(String.init) ?? sel
            list.append(TapAudioTarget(bundleID: sel, displayName: name, isOnAudioGraph: false))
            list.sort {
                if $0.isOnAudioGraph != $1.isOnAudioGraph { return $0.isOnAudioGraph && !$1.isOnAudioGraph }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        tapTargets = list
    }

    func trySyncEngine() {
        permission.refresh()
        refreshTapTargets()

        guard permission.status == .authorized else {
            statusMessage = "Allow audio capture when prompted (or in System Settings)."
            stopEngineIfRunning()
            return
        }

        let bundleID = settings.targetBundleID
        guard !bundleID.isEmpty else {
            statusMessage = "Choose an app to transpose."
            stopEngineIfRunning()
            return
        }

        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else {
            statusMessage = "Launch the selected app, then try again."
            stopEngineIfRunning()
            return
        }

        let ids: [AudioObjectID]
        do {
            ids = try AudioTapTargetResolver.processObjectIDs(bundleID: bundleID)
        } catch {
            statusMessage = error.localizedDescription
            stopEngineIfRunning()
            return
        }

        let outUID: String
        do {
            outUID = try AudioDeviceID.readDefaultOutputDevice().readDeviceUID()
        } catch {
            statusMessage = "Could not read default output device."
            lastError = error.localizedDescription
            stopEngineIfRunning()
            return
        }

        let semi = settings.semitoneOffset
        let appLabel = tapTargets.first(where: { $0.bundleID == bundleID })?.displayName ?? bundleID

        if engine.isRunning {
            do {
                _ = try AudioTapTargetResolver.processObjectIDs(bundleID: bundleID)
                engine.updateSemitones(semi)
                statusMessage = semi == 0
                    ? "Connected — \(appLabel) (0 semitones)."
                    : "Transposing \(appLabel): \(formatSemitones(semi))."
            } catch {
                engine.stop()
                statusMessage = error.localizedDescription
            }
            return
        }

        if userStoppedPipeline {
            statusMessage = "Pipeline stopped. Click “Start pipeline” to reconnect."
            return
        }

        do {
            try engine.activate(processObjectIDs: ids, outputDeviceUID: outUID, semitones: semi)
            lastError = nil
            statusMessage = semi == 0
                ? "Connected — \(appLabel). Adjust the slider to transpose."
                : "Transposing \(appLabel): \(formatSemitones(semi))."
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func stopEngineIfRunning() {
        guard engine.isRunning else { return }
        engine.stop()
    }

    func stop() {
        userStoppedPipeline = true
        engine.stop()
        statusMessage = "Stopped."
    }

    func startPipeline() {
        userStoppedPipeline = false
        trySyncEngine()
    }

    func requestPermission() {
        permission.request()
    }

    func onSemitonesChanged(_ value: Float) {
        let stepped = Float(min(12, max(-12, Int(round(value)))))
        settings.semitoneOffset = stepped
        engine.updateSemitones(stepped)
    }

    func onTargetBundleChanged(_ bundleID: String) {
        guard bundleID != settings.targetBundleID else { return }
        settings.targetBundleID = bundleID
        if engine.isRunning {
            engine.stop()
        }
        userStoppedPipeline = false
        trySyncEngine()
    }

    private func formatSemitones(_ s: Float) -> String {
        String(format: "%+.0f semitones", s)
    }
}
