import AppKit
import SwiftUI

/// The recording overlay.
///
/// It must never take focus: the whole point is that the caret stays exactly where the user
/// left it, in the app they are dictating into. A non-activating panel that refuses to become
/// key or main gives that, and joining all Spaces keeps it visible in full-screen apps.
@MainActor
final class HUDPanel: NSPanel {
    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 92),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
    }

    // Refusing key and main status is what keeps the target app's caret alive.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the panel near the top of the screen holding the pointer, above the caret area
    /// but clear of the menu bar.
    func positionNearTop() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = self.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 24
        )
        setFrameOrigin(origin)
    }

    func present() {
        positionNearTop()
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}
