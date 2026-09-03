import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var setupWindow: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Visprflow launched as \(Bundle.main.bundleIdentifier ?? "unknown bundle", privacy: .public)")

        state.onShowSetup = { [weak self] in self?.showSetup() }

        do {
            try Database.open()
        } catch {
            Log.db.error("Database failed to open: \(error.localizedDescription, privacy: .public)")
        }

        state.refreshPermissions()
        if !state.permissions.allGranted {
            showSetup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindowController(state: state)
        }
        setupWindow?.show()
    }
}
