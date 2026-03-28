import SwiftUI

@main
struct ToneposeApp: App {
    @State private var viewModel = TransposeViewModel()

    var body: some Scene {
        MenuBarExtra("tonepose", systemImage: "music.note") {
            TransposePopover(model: viewModel)
        }
        .menuBarExtraStyle(.window)

        Window("tonepose — apps", id: "tonepose-apps") {
            TransposeAppsWindow(model: viewModel)
        }
    }
}
