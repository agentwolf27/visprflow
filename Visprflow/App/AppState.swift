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
    /// Persisted as JSON, because a trigger is now any key the keyboard can send rather than
    /// one of a fixed pair.
    var triggerKey: TriggerKey = {
        if let data = UserDefaults.standard.data(forKey: "triggerKeyV2"),
           let decoded = try? JSONDecoder().decode(TriggerKey.self, from: data) {
            return decoded
        }
        return .fn
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
    /// True while the app is waiting for the user to press their chosen key.
    var isRecordingTrigger = false

    /// Asks the event tap to report the next key pressed, and adopts it as the trigger.
    func recordTriggerKey() {
        guard let dictation else { return }
        isRecordingTrigger = true
        dictation.recordNextKey { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                self.isRecordingTrigger = false
                self.setTriggerKey(key)
            }
        }
    }

    func cancelTriggerRecording() {
        isRecordingTrigger = false
        dictation?.cancelKeyRecording()
    }

    func setTriggerKey(_ key: TriggerKey) {
        guard key != triggerKey else { return }
        triggerKey = key
        if let data = try? JSONEncoder().encode(key) {
            UserDefaults.standard.set(data, forKey: "triggerKeyV2")
        }
        dictation?.setTrigger(key)
        Log.hotkey.info("Trigger key changed to \(key.displayName, privacy: .public) (code \(key.keyCode, privacy: .public), mask \(key.flagMask, privacy: .public))")
    }
}
