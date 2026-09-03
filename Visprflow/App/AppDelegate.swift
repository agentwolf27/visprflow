import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) lazy var dictation = DictationController(trigger: state.triggerKey)
    private var setupWindow: SetupWindowController?
    private var settingsWindow: SettingsWindowController?
    private var permissionPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit tests are app-hosted, so this runs during `make test` too. Without this
        // guard a test run would migrate the developer's real history database and steal focus.
        guard NSClassFromString("XCTestCase") == nil else {
            Log.app.info("Launched as a test host; skipping app startup")
            return
        }
        Log.app.info("Visprflow launched as \(Bundle.main.bundleIdentifier ?? "unknown bundle", privacy: .public)")

        state.onShowSetup = { [weak self] in self?.showSetup() }
        state.onShowSettings = { [weak self] in self?.showSettings() }
        state.dictation = dictation

        do {
            try Database.open()
        } catch {
            Log.db.error("Database failed to open: \(error.localizedDescription, privacy: .public)")
        }

        state.refreshPermissions()
        if state.permissions.allGranted {
            startDictation()
        } else {
            showSetup()
            // The grants land while the app is running, so watch for them and start then.
            watchForPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.stop()
    }

    /// Launching the app again while it is already running should bring the setup window back.
    /// Without this, a menu bar app with no Dock icon has no obvious way to reopen it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSetup()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Private

    private func startDictation() {
        guard !state.isListening else { return }
        do {
            try dictation.start()
            state.isListening = true
            Log.app.info("Hotkey monitor running; hold \(self.state.triggerKey.displayName, privacy: .public) to dictate")
            Task { await dictation.warmUp() }
        } catch {
            state.startupError = error.localizedDescription
            Log.app.error("Could not start the hotkey monitor: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func watchForPermissions() {
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.refreshPermissions()
                guard self.state.permissions.allGranted else { return }
                self.permissionPoll?.invalidate()
                self.permissionPoll = nil
                self.startDictation()
            }
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    private func showSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindowController(state: state)
        }
        setupWindow?.show()
    }
}
