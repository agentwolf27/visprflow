import AppKit
import ApplicationServices
import Foundation

/// Reads what is focused right now: the app, its window title, the browser address, and the
/// command running inside a terminal.
///
/// Split into two halves on purpose. `frontmost()` is cheap and safe to call from inside the
/// event-tap callback. `enrich(_:)` shells out to `ps`, `lsof`, `git` and AppleScript, none of
/// which may run on that callback: macOS disables an event tap whose callback is slow, and a
/// disabled tap loses the key-up and throws the dictation away. So the slow half runs off the
/// latency path while the user is still speaking, and is joined only when the transcript is ready.
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

    /// The cheap half: bundle identifier and secure-input state, both in-memory lookups.
    /// Safe to call synchronously from the event-tap callback.
    @MainActor
    static func frontmost() -> FocusContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FocusContext(isSecureInput: SecureInput.isActive)
        }
        return FocusContext(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            isSecureInput: SecureInput.isActive
        )
    }

    /// The slow half: window title, terminal process, working directory and browser address.
    /// Never call this from the event-tap callback.
    static func enrich(_ context: FocusContext) -> FocusContext {
        var result = context
        guard let bundle = context.bundleIdentifier, let pid = context.processIdentifier else {
            return result
        }
        result.windowTitle = windowTitle(pid: pid)

        if DestinationResolver.terminalBundles.contains(bundle) {
            if let foreground = ProcessTree.foreground(under: pid) {
                result.terminalProcess = foreground.isAgent ? foreground.command : "shell"
                // The working directory of whatever is running is the project the user means.
                if let directory = WorkspaceProbe.workingDirectory(of: foreground.pid) {
                    result.workspace = WorkspaceProbe.probe(directory: directory)
                }
            }
        }
        if DestinationResolver.browserBundles.contains(bundle) {
            result.browserURL = browserURL(bundle: bundle)
        }
        return result
    }

    /// Title of the app's focused window, read through Accessibility with a bounded timeout.
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

    /// Address of the front tab.
    ///
    /// Run through `osascript` rather than `NSAppleScript` so it inherits a hard timeout:
    /// `NSAppleScript` waits up to a minute by default, and a beachballed browser would
    /// otherwise stall the dictation.
    static func browserURL(bundle: String) -> String? {
        guard let source = browserScripts[bundle] else { return nil }
        let output = WorkspaceProbe.run("/usr/bin/osascript", ["-e", source], timeout: 1.0)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
