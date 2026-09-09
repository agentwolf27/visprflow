import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which key starts a dictation.
///
/// Deliberately not an enum of two presets. Compact and third-party keyboards vary enormously:
/// many have no Right Option at all, some send a different key entirely under the same label,
/// and `fn` only reaches applications from Apple's built-in keyboard. So the key is stored as
/// whatever the keyboard actually sends, and the setup window records it by asking the user to
/// press it.
struct TriggerKey: Codable, Sendable, Equatable, Hashable {
    /// The hardware key code the keyboard sends.
    var keyCode: CGKeyCode
    /// For a modifier key, the device-dependent flag bit set while it is held. Zero for an
    /// ordinary key, which is tracked through keyDown and keyUp instead.
    var flagMask: UInt64
    /// What to call it in the interface.
    var displayName: String

    /// Modifier keys make better triggers: they are held rather than typed, they do not repeat,
    /// and they insert nothing if the tap misses them.
    var isModifier: Bool { flagMask != 0 }

    /// True when this key is currently held, given an event's flags.
    func isHeld(in flags: CGEventFlags) -> Bool {
        guard isModifier else { return false }
        return flags.rawValue & flagMask != 0
    }

    // MARK: Presets

    /// The fn / Globe key. Only reaches this process from Apple's built-in keyboard.
    static let fn = TriggerKey(
        keyCode: CGKeyCode(kVK_Function),
        flagMask: CGEventFlags.maskSecondaryFn.rawValue,
        displayName: "fn (Globe)"
    )

    static let rightOption = TriggerKey(
        keyCode: CGKeyCode(kVK_RightOption),
        flagMask: Self.deviceFlag(forModifier: CGKeyCode(kVK_RightOption)) ?? 0,
        displayName: "Right Option"
    )

    static let rightCommand = TriggerKey(
        keyCode: CGKeyCode(kVK_RightCommand),
        flagMask: Self.deviceFlag(forModifier: CGKeyCode(kVK_RightCommand)) ?? 0,
        displayName: "Right Command"
    )

    static let presets: [TriggerKey] = [.fn, .rightOption, .rightCommand]

    // MARK: Suitability

    /// Why a key is a poor choice of trigger, or nil when it is fine.
    ///
    /// The app does not refuse these: a keyboard with no spare modifier may leave the user no
    /// better option, and it is their machine. But choosing Left Shift means every capital
    /// letter starts a dictation, which is worth saying plainly before they find out by typing.
    var unsuitableReason: String? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:
            "Shift types capital letters, so every capital would start a dictation."
        case kVK_CapsLock:
            "Caps Lock is handled by the system before apps see it, and toggles a state."
        case kVK_Escape:
            "Escape already cancels a dictation."
        case kVK_Return, kVK_ANSI_KeypadEnter:
            "Return sends messages and inserts newlines."
        case kVK_Space:
            "Space is the most common key you type."
        case kVK_Tab:
            "Tab moves between fields."
        case kVK_Delete, kVK_ForwardDelete:
            "Delete is used constantly while editing."
        default:
            ordinaryKeyReason
        }
    }

    /// An ordinary printing key types its character everywhere, so holding it to talk means
    /// never being able to type it again.
    private var ordinaryKeyReason: String? {
        guard !isModifier else { return nil }
        // Function keys and the navigation cluster are safe: they print nothing.
        let safeOrdinary: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help,
        ]
        if safeOrdinary.contains(Int(keyCode)) { return nil }
        return "This key types a character, so holding it to talk would stop you typing it."
    }

    var isSuitable: Bool { unsuitableReason == nil }

    // MARK: Recognising a pressed key

    /// Device-dependent flag bits. macOS sets one of these alongside the general mask (such as
    /// `.maskAlternate`) so the left and right keys of a pair can be told apart. The general
    /// mask is useless as a trigger: it stays set while *either* key is held, so holding the
    /// left one would swallow the right one's release.
    ///
    /// These values are the `NX_DEVICE*` masks from IOKit's event headers.
    private static let deviceFlags: [Int: UInt64] = [
        kVK_Control: 0x0000_0001,       // NX_DEVICELCTLKEYMASK
        kVK_Shift: 0x0000_0002,         // NX_DEVICELSHIFTKEYMASK
        kVK_RightShift: 0x0000_0004,    // NX_DEVICERSHIFTKEYMASK
        kVK_Command: 0x0000_0008,       // NX_DEVICELCMDKEYMASK
        kVK_RightCommand: 0x0000_0010,  // NX_DEVICERCMDKEYMASK
        kVK_Option: 0x0000_0020,        // NX_DEVICELALTKEYMASK
        kVK_RightOption: 0x0000_0040,   // NX_DEVICERALTKEYMASK
        kVK_RightControl: 0x0000_2000,  // NX_DEVICERCTLKEYMASK
        kVK_Function: 0x0080_0000,      // kCGEventFlagMaskSecondaryFn
        kVK_CapsLock: 0x0001_0000,      // kCGEventFlagMaskAlphaShift
    ]

    static func deviceFlag(forModifier keyCode: CGKeyCode) -> UInt64? {
        deviceFlags[Int(keyCode)]
    }

    static func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        deviceFlags[Int(keyCode)] != nil
    }

    /// Builds a trigger from a key the user just pressed.
    static func recognised(keyCode: CGKeyCode, flags: CGEventFlags) -> TriggerKey {
        if let mask = deviceFlag(forModifier: keyCode) {
            return TriggerKey(keyCode: keyCode, flagMask: mask, displayName: name(for: keyCode))
        }
        return TriggerKey(keyCode: keyCode, flagMask: 0, displayName: name(for: keyCode))
    }

    /// A readable name for a key code, so the setup window can say what it captured.
    static func name(for keyCode: CGKeyCode) -> String {
        if let known = namedKeys[Int(keyCode)] { return known }
        if let character = character(for: keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    private static let namedKeys: [Int: String] = [
        kVK_Function: "fn (Globe)",
        kVK_Control: "Left Control", kVK_RightControl: "Right Control",
        kVK_Shift: "Left Shift", kVK_RightShift: "Right Shift",
        kVK_Option: "Left Option", kVK_RightOption: "Right Option",
        kVK_Command: "Left Command", kVK_RightCommand: "Right Command",
        kVK_CapsLock: "Caps Lock",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Escape",
        kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "Left Arrow", kVK_RightArrow: "Right Arrow",
        kVK_UpArrow: "Up Arrow", kVK_DownArrow: "Down Arrow",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The character a key produces under the current layout, so "Key 12" reads as "Q".
    private static func character(for keyCode: CGKeyCode) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
