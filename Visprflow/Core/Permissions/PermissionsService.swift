import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// The TCC grants the app can use.
///
/// Only Microphone and Accessibility are required. Input Monitoring is listed because macOS
/// mentions it for keyboard hooks, but this app creates an *active* event tap
/// (`options: .defaultTap`), which is gated on Accessibility. A listen-only tap is what needs
/// Input Monitoring, and requiring it here meant waiting for a checkbox that never appeared:
/// an app that never opens a listen-only tap is never added to that list.
enum Permission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var why: String {
        switch self {
        case .microphone:
            "Records your voice while the key is held. Audio is transcribed on this Mac and never uploaded."
        case .accessibility:
            "Watches for your trigger key and pastes the result into the app you are using. This is the one that matters."
        case .inputMonitoring:
            "Not required. Visprflow uses an active event tap, which macOS gates on Accessibility instead."
        }
    }

    /// Whether the app refuses to run without this grant.
    var isRequired: Bool {
        switch self {
        case .microphone, .accessibility: true
        case .inputMonitoring: false
        }
    }

    /// Whether macOS will reliably show a prompt, or whether the user must tick a box.
    ///
    /// Microphone shows a real dialog. Accessibility and Input Monitoring show a one-shot
    /// notice that a menu bar app can easily lose behind other windows, and after any denial
    /// they never show it again. For those two the request registers the app in the list, and
    /// the user ticks the box in System Settings.
    var needsSettingsPane: Bool {
        switch self {
        case .microphone: false
        case .accessibility, .inputMonitoring: true
        }
    }

    /// Deep link into System Settings → Privacy & Security for this grant.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

struct PermissionStatus: Equatable, Sendable, CustomStringConvertible {
    var microphone = false
    var accessibility = false
    var inputMonitoring = false

    /// Everything the app actually needs. Input Monitoring is deliberately not included.
    var allGranted: Bool { microphone && accessibility }

    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }

    var description: String {
        Permission.allCases
            .map { "\($0.rawValue)=\(isGranted($0) ? "granted" : "missing")" }
            .joined(separator: " ")
    }
}

enum PermissionsService {
    /// Snapshot of the current grants. Cheap enough to poll once a second while the setup window is open.
    static func current() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    /// Triggers the system prompt for the grant. macOS shows each prompt once; after a denial
    /// the only route is System Settings, which `openSettings(for:)` opens.
    static func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.permissions.info("Microphone request result: \(granted, privacy: .public)")
        case .accessibility:
            // The literal value of kAXTrustedCheckOptionPrompt. Referencing the C global
            // directly is not concurrency-safe under Swift 6 strict checking.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            Log.permissions.info("Accessibility prompt shown; trusted now: \(trusted, privacy: .public)")
        case .inputMonitoring:
            let granted = CGRequestListenEventAccess()
            Log.permissions.info("Input Monitoring request result: \(granted, privacy: .public)")
        }
    }

    @MainActor
    static func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}
