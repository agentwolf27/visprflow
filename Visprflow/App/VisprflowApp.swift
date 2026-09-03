import SwiftUI

@main
struct VisprflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(delegate.state)
        } label: {
            Image(systemName: delegate.state.permissions.allGranted ? "mic.fill" : "mic.slash.fill")
                .accessibilityLabel("Visprflow")
        }
        .menuBarExtraStyle(.window)
    }
}
