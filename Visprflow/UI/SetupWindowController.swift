import AppKit
import SwiftUI

/// Hosts the onboarding view in an AppKit window so the app delegate can open it at launch
/// and bring it to the front, which an LSUIElement app has to do explicitly.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
        let host = NSHostingController(rootView: OnboardingView().environment(state))
        let window = NSWindow(contentViewController: host)
        window.title = "Visprflow Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SetupWindowController is created in code")
    }

    /// Disarms the trigger recorder when the window closes.
    ///
    /// The recorder swallows the next key pressed anywhere on the system. Left armed after the
    /// window is gone, the next character typed in any app would vanish and silently become the
    /// global trigger.
    func windowWillClose(_ notification: Notification) {
        state?.cancelTriggerRecording()
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}


/// Window for the per-destination settings.
@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let host = NSHostingController(rootView: DestinationSettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "Visprflow Destinations"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code")
    }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
