import AppKit
import SwiftUI

/// Hosts the onboarding view in an AppKit window so the app delegate can open it at launch
/// and bring it to the front, which an LSUIElement app has to do explicitly.
@MainActor
final class SetupWindowController: NSWindowController {
    init(state: AppState) {
        let host = NSHostingController(rootView: OnboardingView().environment(state))
        let window = NSWindow(contentViewController: host)
        window.title = "Visprflow Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SetupWindowController is created in code")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
