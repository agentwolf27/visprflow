import AppKit
import ApplicationServices
import Foundation

/// Reads what is focused right now: the app, its window title, the browser address, and the
/// command running inside a terminal.
///
/// Everything here is best-effort. A missing piece degrades the destination guess rather than
/// failing the dictation, because inserting slightly under-edited text is always better than
/// inserting nothing.
@MainActor
enum FocusContextProvider {
    /// AppleScript to read the front tab's address, per browser family.
    private static let browserScripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "com.google.Chrome.canary": "tell application \"Google Chrome Canary\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
        "com.vivaldi.Vivaldi": "tell application \"Vivaldi\" to return URL of active tab of front window",
    ]

    /// Snapshot of the focused window. Call on key-down, before the overlay appears.
    static func current() -> FocusContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FocusContext(isSecureInput: SecureInput.isActive)
        }
        let bundle = app.bundleIdentifier

        var context = FocusContext(
            bundleIdentifier: bundle,
            windowTitle: windowTitle(pid: app.processIdentifier),
            isSecureInput: SecureInput.isActive
        )

        if let bundle, DestinationResolver.terminalBundles.contains(bundle) {
            if let foreground = ProcessTree.foreground(under: app.processIdentifier) {
                context.terminalProcess = foreground.isAgent ? foreground.command : "shell"
                // The working directory of whatever is running is the project the user means.
                if let directory = WorkspaceProbe.workingDirectory(of: foreground.pid) {
                    context.workspace = WorkspaceProbe.probe(directory: directory)
                }
            }
        }
        if let bundle, DestinationResolver.browserBundles.contains(bundle) {
            context.browserURL = browserURL(bundle: bundle)
        }
        return context
    }

    /// Title of the app's focused window, read through Accessibility.
    static func windowTitle(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let element = window as! AXUIElement?
        else { return nil }

        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    /// Address of the front tab. Needs Automation permission, and returns nil without it
    /// rather than prompting mid-dictation.
    static func browserURL(bundle: String) -> String? {
        guard let source = browserScripts[bundle] else { return nil }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.app.debug("Browser URL unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result.stringValue
    }
}
