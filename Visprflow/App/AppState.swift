import Observation

/// Observable state shared by the menu bar content and the setup window.
@MainActor
@Observable
final class AppState {
    var permissions = PermissionStatus()
    /// True once the hotkey monitor is running.
    var isListening = false
    /// Set when the monitor could not start, so the setup window can explain why.
    var startupError: String?
    var triggerKey: TriggerKey = .fn

    /// How the fn key is currently configured system-wide. When it is not "Do Nothing" the
    /// system opens the emoji picker on a tap, which competes with using fn as a trigger.
    var fnUsage: FnKeyUsage = .current

    @ObservationIgnored
    var dictation: DictationController?

    @ObservationIgnored
    var onShowSetup: (@MainActor () -> Void)?

    @ObservationIgnored
    var onShowSettings: (@MainActor () -> Void)?

    func refreshPermissions() {
        let latest = PermissionsService.current()
        if latest != permissions {
            Log.permissions.info("Permissions changed: \(latest.description, privacy: .public)")
            permissions = latest
        }
        fnUsage = .current
    }

    func showSetup() {
        onShowSetup?()
    }

    func showSettings() {
        onShowSettings?()
    }

    /// Changes the trigger key and tells the running monitor about it.
    func setTriggerKey(_ key: TriggerKey) {
        guard key != triggerKey else { return }
        triggerKey = key
        dictation?.setTrigger(key)
        Log.hotkey.info("Trigger key changed to \(key.rawValue, privacy: .public)")
    }
}
