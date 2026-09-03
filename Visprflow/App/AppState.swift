import Foundation
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
    /// Persisted, so a choice of Right Option survives a restart. fn only reaches apps from
    /// the built-in keyboard, so anyone on an external keyboard has to change this.
    var triggerKey: TriggerKey = {
        let stored = UserDefaults.standard.string(forKey: "triggerKey")
        return stored.flatMap(TriggerKey.init(rawValue:)) ?? .fn
    }()

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

    /// One line describing whether dictation is actually live, for the menu bar.
    var statusSummary: String {
        if isListening { return "Listening" }
        if startupError != nil { return "Failed to start" }
        return permissions.allGranted ? "Starting…" : "Needs setup"
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
        UserDefaults.standard.set(key.rawValue, forKey: "triggerKey")
        dictation?.setTrigger(key)
        Log.hotkey.info("Trigger key changed to \(key.rawValue, privacy: .public)")
    }
}
