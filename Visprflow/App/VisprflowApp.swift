import SwiftUI

@main
struct VisprflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(delegate.state)
        } label: {
            // Read through a View so Observation actually tracks it. Reading
            // `state.permissions` directly in this builder samples it once, during Scene
            // construction, and the icon would never update.
            MenuBarIcon(state: delegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}


/// The menu bar glyph. A View, so `@Observable` tracking applies and the icon follows
/// permission changes instead of freezing at its launch value.
private struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        Image(systemName: state.permissions.allGranted ? "mic.fill" : "mic.slash.fill")
            .accessibilityLabel(state.permissions.allGranted ? "Visprflow, ready" : "Visprflow, setup needed")
    }
}
