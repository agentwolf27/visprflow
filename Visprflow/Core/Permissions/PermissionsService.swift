import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// The three TCC grants the app needs. Screen Recording and Apple Events arrive in phase 3,
/// only when the user turns on the features that need them.
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
            "Lets Visprflow paste the compiled prompt into the app you are using and read the text you selected."
        case .inputMonitoring:
            "Lets Visprflow notice when you hold the fn key, in any app."
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

    var allGranted: Bool { microphone && accessibility && inputMonitoring }

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
