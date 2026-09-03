import Carbon.HIToolbox
import Foundation

/// Finds the virtual keycode that types a given character on the *current* keyboard layout.
///
/// Hardcoding 0x09 for "v" is the classic bug in this category: on Dvorak, AZERTY or Colemak
/// that keycode is a different letter, so the synthesised ⌘V pastes nothing (or does something
/// worse). Resolving the keycode through the active layout fixes every layout at once.
enum KeycodeResolver {
    /// Virtual keycode for "v" on a US QWERTY layout, used as the fallback.
    static let qwertyV: CGKeyCode = 0x09

    /// Scans the active layout for the keycode that produces `character` with no modifiers.
    /// Returns nil when the layout cannot be read, so callers can fall back.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character).lowercased()

        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            // Virtual keycodes for the main alphanumeric block. Scanning the whole 0...127
            // range would also match keypad and function keys, which we never want here.
            for code in CGKeyCode(0)...CGKeyCode(50) {
                if translate(code: code, layout: layout)?.lowercased() == target {
                    return code
                }
            }
            return nil
        }
    }

    /// The character a keycode produces with no modifiers held, or nil for non-printing keys.
    private static func translate(code: CGKeyCode, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            layout,
            UInt16(code),
            UInt16(kUCKeyActionDisplay),
            0, // no modifiers
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
