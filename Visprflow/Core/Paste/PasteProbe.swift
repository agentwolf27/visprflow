import AppKit
import ApplicationServices
import CoreGraphics

/// Phase 0 smoke test for the Accessibility grant: puts a marker on the pasteboard, posts ⌘V,
/// then restores whatever was on the clipboard before.
///
/// Phase 1 replaces this with the real `Inserter`: pasteboard promise used as a read receipt
/// before restoring, layout-aware keycode lookup through `UCKeyTranslate`, and the AX path
/// for native fields. Keep this file small; it exists only so the setup window can prove the
/// grant works end to end.
@MainActor
enum PasteProbe {
    static let marker = "Visprflow test paste ✓"

    enum Outcome: Equatable {
        case posted
        case notTrusted
    }

    static func run() -> Outcome {
        guard AXIsProcessTrusted() else {
            Log.insert.warning("Paste probe skipped: process is not trusted for Accessibility")
            return .notTrusted
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let ourChangeCount = pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        // Clipboard managers honour this marker and skip the entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            postCommandV()
            Log.insert.info("Paste probe posted ⌘V")

            try? await Task.sleep(for: .milliseconds(500))
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount == ourChangeCount, let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return .posted
    }

    /// Virtual key 0x09 is "v" on QWERTY only. Phase 1 resolves the keycode from the active layout.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
