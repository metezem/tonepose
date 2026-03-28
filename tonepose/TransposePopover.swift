import AppKit
import SwiftUI

struct TransposePopover: View {
    @Bindable var model: TransposeViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let canUseAudio = model.permission.status == .authorized
        let quickList = TransposeQuickList.rows(
            tapTargets: model.tapTargets,
            pinnedBundleIDs: model.settings.pinnedBundleIDs
        )

        VStack(alignment: .leading, spacing: 12) {
            Text("Tonepose")
                .font(.headline)

            if model.permission.status != .authorized {
                Text("Transpose audio from a chosen app using Core Audio. macOS must allow audio capture for this app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Allow audio capture…") {
                    model.requestPermission()
                }
                Button("Open System Settings") {
                    model.permission.openSystemSettings()
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("App to transpose")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage apps…") {
                        openWindow(id: "tonepose-apps")
                    }
                    .font(.caption)
                    .controlSize(.small)
                }

                if quickList.isEmpty {
                    Text("No apps on the quick list. Open Manage apps to pin a process or start a catalog app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.settings.targetBundleID },
                            set: { model.onTargetBundleChanged($0) }
                        )
                    ) {
                        ForEach(quickList) { row in
                            Text(row.isOnAudioGraph ? row.displayName : "\(row.displayName) — start audio")
                                .tag(row.bundleID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Text("Semitones")
                    Spacer()
                    Text(String(format: "%+.0f", model.settings.semitoneOffset))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(model.settings.semitoneOffset) },
                    set: { model.onSemitonesChanged(Float($0)) }
                ), in: -12...12, step: 1)
                HStack {
                    Button("Reset") {
                        model.onSemitonesChanged(0)
                    }
                    .disabled(model.settings.semitoneOffset == 0)
                    Spacer()
                    if model.isEngineRunning {
                        Button("Stop pipeline") {
                            model.stop()
                        }
                    } else if model.userStoppedPipeline {
                        Button("Start pipeline") {
                            model.startPipeline()
                        }
                    }
                }
            }
            .disabled(!canUseAudio)
            .opacity(canUseAudio ? 1 : 0.45)

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(canUseAudio ? 1 : 0.45)

            if let err = model.lastError, model.permission.status == .authorized {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Quit") {
                    model.stop()
                    NSApplication.shared.terminate(nil)
                }
                .font(.footnote)
                .controlSize(.regular)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear {
            model.trySyncEngine()
            syncSelectionIfNeeded()
        }
        .onChange(of: model.tapTargets.count) { _, _ in
            syncSelectionIfNeeded()
        }
        .onChange(of: model.settings.pinnedBundleIDs) { _, _ in
            syncSelectionIfNeeded()
        }
    }

    private func syncSelectionIfNeeded() {
        let fresh = TransposeQuickList.rows(
            tapTargets: model.tapTargets,
            pinnedBundleIDs: model.settings.pinnedBundleIDs
        )
        let ids = Set(fresh.map(\.bundleID))
        guard let first = fresh.first else { return }
        if !ids.contains(model.settings.targetBundleID) {
            model.onTargetBundleChanged(first.bundleID)
        }
    }
}

#Preview {
    TransposePopover(model: TransposeViewModel())
}
