import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// How text should reach the focused field.
enum InsertionStrategy: String, Codable, Sendable, CaseIterable {
    /// Clipboard plus a synthesised paste chord. Works nearly everywhere.
    case paste
    /// Shift+Insert instead of ⌘V, for Electron terminals that treat ⌘V as an image paste.
    case pasteShiftInsert
    /// Replace the Accessibility selection directly, leaving the clipboard untouched.
    case accessibility
    /// Synthesise the characters one at a time. Slow; the last resort.
    case typing
}

enum InsertionError: Error, LocalizedError {
    case notTrusted
    case secureInputActive
    case accessibilityRefused
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            "Visprflow needs Accessibility permission to insert text."
        case .secureInputActive:
            "The focused field has secure input on, so text cannot be inserted. The transcript is on your clipboard."
        case .accessibilityRefused:
            "That app would not accept the text through Accessibility."
        case .eventCreationFailed:
            "Could not synthesise the paste keystroke."
        }
    }
}

/// Puts text into whatever field is focused, then leaves the user's clipboard exactly as it was.
@MainActor
final class Inserter {
    private let policy: PasteRestorePolicy
    /// Marks our own pasteboard entry so we never restore over someone else's copy.
    private static let sessionType = NSPasteboard.PasteboardType("com.vish.visprflow.session")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    init(policy: PasteRestorePolicy = .default) {
        self.policy = policy
    }

    /// Inserts `text`, choosing the mechanism the target app tolerates.
    func insert(_ text: String, strategy: InsertionStrategy) async throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw InsertionError.notTrusted }
        if SecureInput.isActive {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            throw InsertionError.secureInputActive
        }

        switch strategy {
        case .accessibility:
            do {
                try insertViaAccessibility(text)
            } catch {
                Log.insert.info("Accessibility insert refused; falling back to paste")
                try await paste(text, chord: .commandV)
            }
        case .paste:
            try await paste(text, chord: .commandV)
        case .pasteShiftInsert:
            try await paste(text, chord: .shiftInsert)
        case .typing:
            try type(text)
        }
    }

    // MARK: Accessibility

    /// Replaces the focused element's selection. Leaves the clipboard alone, but many apps
    /// (terminals, most Electron views, web content) either refuse it or apply it wrongly.
    private func insertViaAccessibility(_ text: String) throws {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement?
        else { throw InsertionError.accessibilityRefused }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { throw InsertionError.accessibilityRefused }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
        else { throw InsertionError.accessibilityRefused }

        Log.insert.info("Inserted \(text.count) characters through Accessibility")
    }

    // MARK: Paste

    private enum PasteChord {
        case commandV
        case shiftInsert
    }

    private func paste(_ text: String, chord: PasteChord) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        await waitForModifiersToClear()

        let owner = PasteOwner(text: text)
        let ourChangeCount = pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.sessionType, Self.transientType], owner: owner)
        // Clipboard managers honour these markers and skip the entry entirely.
        pasteboard.setString("", forType: Self.transientType)

        try postPasteChord(chord)
        let postedAt = ContinuousClock.now

        // Wait for the target app to actually read our data, then restore.
        while true {
            let elapsed = Trace.milliseconds(ContinuousClock.now - postedAt) / 1000
            let lastReceipt = owner.lastReadAt.map { Trace.milliseconds(ContinuousClock.now - $0) / 1000 }
            let changed = pasteboard.changeCount != ourChangeCount

            switch policy.decide(elapsed: elapsed, lastReceipt: lastReceipt, pasteboardChanged: changed) {
            case let .wait(interval):
                try? await Task.sleep(for: .seconds(interval))
            case .abandon:
                Log.insert.info("Pasteboard changed under us; leaving the newer contents in place")
                return
            case .restore:
                if pasteboard.changeCount == ourChangeCount {
                    snapshot.restore(to: pasteboard)
                    Log.insert.info("Inserted \(text.count) characters and restored the clipboard\(owner.wasRead ? "" : " (no read receipt)")")
                }
                return
            }
        }
    }

    /// Physical modifiers that would corrupt a synthetic ⌘V. Shift is the dangerous one:
    /// it is the verbatim trigger, so it is often still held when the paste fires, and ⌘⇧V is
    /// "Paste and Match Style" in most apps.
    private static let contaminatingFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]

    /// Waits briefly for the user to let go of any modifier that would change what ⌘V means.
    private func waitForModifiersToClear() async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while ContinuousClock.now < deadline {
            let held = CGEventSource.flagsState(.combinedSessionState)
            if held.intersection(Self.contaminatingFlags).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Log.insert.info("Pasting with a modifier still held; the chord sets its own flags explicitly")
    }

    private func postPasteChord(_ chord: PasteChord) throws {
        // A private source does not inherit the hardware modifier state the way
        // `.combinedSessionState` does, so the chord is exactly what we set below.
        guard let source = CGEventSource(stateID: .privateState) else {
            throw InsertionError.eventCreationFailed
        }
        // Suppress local keyboard events for a moment so a key the user is still holding
        // cannot combine with our synthetic chord.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let key: CGKeyCode
        let flags: CGEventFlags
        switch chord {
        case .commandV:
            key = KeycodeResolver.keyCode(for: "v") ?? KeycodeResolver.qwertyV
            flags = .maskCommand
        case .shiftInsert:
            key = CGKeyCode(kVK_Help) // Insert shares its keycode with Help on Apple layouts.
            flags = .maskShift
        }

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { throw InsertionError.eventCreationFailed }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        // Some Electron and Java apps drop a chord whose down and up land in the same
        // run loop turn, so leave a gap between them.
        usleep(8_000)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: Typing

    /// Synthesises the text as unicode key events. Layout independent and clipboard free, but
    /// slow and unsafe in terminals, where a newline is Enter. Used only as a fallback.
    private func type(_ text: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertionError.eventCreationFailed
        }
        // CGEventKeyboardSetUnicodeString takes a bounded buffer, so send it in chunks that
        // never split a surrogate pair.
        for chunk in text.chunkedUTF16(maxUnits: 16) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw InsertionError.eventCreationFailed }
            var units = chunk
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            usleep(1_500)
        }
        Log.insert.info("Typed \(text.count) characters")
    }
}

// MARK: - Pasteboard promise owner

/// Serves our text lazily and records when someone asked for it. That read is the signal the
/// paste actually landed, which is far more reliable than a fixed delay.
private final class PasteOwner: NSObject, NSPasteboardTypeOwner {
    private let text: String
    private(set) var lastReadAt: ContinuousClock.Instant?
    private(set) var wasRead = false

    init(text: String) {
        self.text = text
    }

    func pasteboard(_ sender: NSPasteboard?, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .string {
            sender?.setString(text, forType: .string)
        }
        wasRead = true
        lastReadAt = ContinuousClock.now
    }
}

// MARK: - Snapshot

/// Everything the pasteboard held, so it can be put back byte for byte.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    var isEmpty: Bool { items.isEmpty }

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
        return PasteboardSnapshot(items: items)
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

// MARK: - Chunking

extension String {
    /// UTF-16 chunks that never split a surrogate pair.
    func chunkedUTF16(maxUnits: Int) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in self {
            let units = Array(String(character).utf16)
            if current.count + units.count > maxUnits, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
