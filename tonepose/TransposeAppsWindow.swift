import AppKit
import SwiftUI

/// Pin/unpin apps and inspect what appears in the menu bar quick list.
struct TransposeAppsWindow: View {
    @Bindable var model: TransposeViewModel

    var body: some View {
        let quickList = TransposeQuickList.rows(
            tapTargets: model.tapTargets,
            pinnedBundleIDs: model.settings.pinnedBundleIDs
        )
        let pinnableTargets = model.tapTargets.filter { !TransposeQuickList.catalogBundleIDs.contains($0.bundleID) }

        NavigationStack {
            Form {
                Section {
                    Text("The menu bar only lists running apps from the built-in catalog (Spotify, Safari, …), plus any pinned app below that is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("On quick list now") {
                    if quickList.isEmpty {
                        Text("None — start playback in a music app or browser, or pin a running app below.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(quickList) { row in
                            LabeledContent {
                                Text(row.isOnAudioGraph ? "On audio graph" : "Start audio in app")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(row.displayName)
                            }
                        }
                    }
                }

                Section("Saved pins") {
                    if model.settings.pinnedBundleIDs.isEmpty {
                        Text("No extra apps pinned.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.settings.pinnedBundleIDs, id: \.self) { bid in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(bundleID: bid))
                                Text(bid)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") {
                                model.settings.unpinBundleID(bid)
                            }
                        }
                    }
                }

                Section("Running apps (pin to add)") {
                    if model.tapTargets.isEmpty {
                        Text("No processes found yet. Start an app and play audio if needed.")
                            .foregroundStyle(.secondary)
                    } else if pinnableTargets.isEmpty {
                        Text("Only built-in catalog apps are running — they already appear on the quick list when active. Start another app to pin it here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pinnableTargets) { t in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.displayName)
                                Text(t.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if model.settings.pinnedBundleIDs.contains(t.bundleID) {
                                Text("Pinned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Remove") {
                                    model.settings.unpinBundleID(t.bundleID)
                                }
                            } else {
                                Button("Pin") {
                                    model.settings.pinBundleID(t.bundleID)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Choose Apps")
        }
        .frame(minWidth: 440, minHeight: 420)
        .onAppear {
            model.trySyncEngine()
        }
    }

    private func displayTitle(bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}

#Preview {
    TransposeAppsWindow(model: TransposeViewModel())
}
