import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) lazy var dictation = DictationController(trigger: state.triggerKey)
    private var setupWindow: SetupWindowController?
    private var settingsWindow: SettingsWindowController?
    private var permissionPoll: Timer?

    /// Objective-C exceptions unwind straight past Swift's `catch`, so a throw inside AppKit or
    /// AVFoundation skips the rest of the function and is swallowed by the run loop. That is
    /// exactly how startup once failed with no error logged at all: the app kept running, the
    /// hotkey never started, and neither the success nor the failure branch was reached.
    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "no reason given"
            let stack = exception.callStackSymbols.prefix(12).joined(separator: " | ")
            Log.app.error("Uncaught ObjC exception: \(name, privacy: .public) — \(reason, privacy: .public) :: \(stack, privacy: .public)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installExceptionHandler()
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
        Log.app.info("Startup permissions: \(self.state.permissions.description, privacy: .public), allGranted=\(self.state.permissions.allGranted, privacy: .public)")
        if state.permissions.allGranted {
            startDictation()
        } else {
            showSetup()
            // The grants land while the app is running, so watch for them and start then.
            watchForPermissions()
        }
        // A grant can also be revoked, or arrive after a failed start, so keep watching either
        // way rather than only when the app began without permission.
        watchForPermissions()
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
        // Logged unconditionally, including the early return. A silent guard here was
        // indistinguishable from a crash while debugging why the key did nothing.
        Log.app.info("startDictation: isListening=\(self.state.isListening, privacy: .public) permissions=\(self.state.permissions.description, privacy: .public)")
        guard !state.isListening else {
            Log.app.info("startDictation: already running, nothing to do")
            return
        }
        do {
            Log.app.info("startDictation: building the controller")
            let controller = dictation
            Log.app.info("startDictation: controller built, starting it")
            try controller.start()
            Log.app.info("startDictation: controller started")
            state.isListening = true
            state.startupError = nil
            Log.app.info("Hotkey monitor running; hold \(self.state.triggerKey.displayName, privacy: .public) to dictate")
            Task { await dictation.warmUp() }
        } catch {
            state.isListening = false
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
                guard self.state.permissions.allGranted, !self.state.isListening else { return }
                self.startDictation()
                if self.state.isListening {
                    self.permissionPoll?.invalidate()
                    self.permissionPoll = nil
                }
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
