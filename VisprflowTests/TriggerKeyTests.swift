import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Visprflow

final class TriggerKeyTests: XCTestCase {
    /// The bug that made Right Option do nothing: the mask was 0x40000, a bit macOS never sets
    /// for it, so the key was never seen as held and no gesture ever started.
    func testRightOptionUsesTheDeviceBitMacOSActuallySets() {
        XCTAssertEqual(TriggerKey.rightOption.flagMask, 0x40)

        // Flags as macOS reports them while Right Option is held: the general Alternate mask
        // plus the right-hand device bit.
        let held = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        XCTAssertTrue(TriggerKey.rightOption.isHeld(in: held))
    }

    /// The general mask stays set while either Option key is down, so it cannot distinguish
    /// them. Holding the left one must not read as the right one being held.
    func testLeftOptionIsNotMistakenForRightOption() {
        let leftHeld = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        XCTAssertFalse(TriggerKey.rightOption.isHeld(in: leftHeld))
        XCTAssertTrue(TriggerKey.recognised(keyCode: CGKeyCode(kVK_Option), flags: leftHeld).isHeld(in: leftHeld))
    }

    func testFnUsesTheSecondaryFunctionMask() {
        XCTAssertEqual(TriggerKey.fn.flagMask, CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertTrue(TriggerKey.fn.isHeld(in: .maskSecondaryFn))
        XCTAssertFalse(TriggerKey.fn.isHeld(in: .maskAlternate))
    }

    func testEveryModifierHasADistinctDeviceBit() {
        let modifiers = [
            kVK_Control, kVK_RightControl, kVK_Shift, kVK_RightShift,
            kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption, kVK_Function,
        ]
        let masks = modifiers.compactMap { TriggerKey.deviceFlag(forModifier: CGKeyCode($0)) }
        XCTAssertEqual(masks.count, modifiers.count, "every modifier needs a mask")
        XCTAssertEqual(Set(masks).count, masks.count, "left and right must not share a bit")
    }

    // MARK: Recording any key

    func testRecognisesAModifierAsAModifier() {
        let key = TriggerKey.recognised(keyCode: CGKeyCode(kVK_RightCommand), flags: [])
        XCTAssertTrue(key.isModifier)
        XCTAssertEqual(key.displayName, "Right Command")
        XCTAssertEqual(key.flagMask, 0x10)
    }

    /// A compact keyboard may have no spare modifier at all, so an ordinary key has to work.
    /// It is tracked by keyDown and keyUp instead of by a flag bit.
    func testRecognisesAnOrdinaryKey() {
        let key = TriggerKey.recognised(keyCode: CGKeyCode(kVK_F13), flags: [])
        XCTAssertFalse(key.isModifier)
        XCTAssertEqual(key.flagMask, 0)
        XCTAssertEqual(key.displayName, "F13")
        // With no flag bit there is nothing to test flags against; it must never claim to be held.
        XCTAssertFalse(key.isHeld(in: .maskAlternate))
    }

    func testNamesKeysReadably() {
        XCTAssertEqual(TriggerKey.name(for: CGKeyCode(kVK_Space)), "Space")
        XCTAssertEqual(TriggerKey.name(for: CGKeyCode(kVK_F5)), "F5")
        XCTAssertEqual(TriggerKey.name(for: CGKeyCode(kVK_RightOption)), "Right Option")
        // Unknown codes still produce something a person can act on.
        XCTAssertFalse(TriggerKey.name(for: CGKeyCode(200)).isEmpty)
    }

    func testIsModifierKeyCodeAgreesWithRecognition() {
        XCTAssertTrue(TriggerKey.isModifierKeyCode(CGKeyCode(kVK_RightOption)))
        XCTAssertFalse(TriggerKey.isModifierKeyCode(CGKeyCode(kVK_ANSI_A)))
    }

    // MARK: Persistence

    func testSurvivesEncodingSoTheChoiceOutlivesARestart() throws {
        let recorded = TriggerKey.recognised(keyCode: CGKeyCode(kVK_RightControl), flags: [])
        let data = try JSONEncoder().encode(recorded)
        let restored = try JSONDecoder().decode(TriggerKey.self, from: data)
        XCTAssertEqual(restored, recorded)
        XCTAssertEqual(restored.flagMask, recorded.flagMask)
    }

    func testPresetsAreAllUsableTriggers() {
        for preset in TriggerKey.presets {
            XCTAssertTrue(preset.isModifier, "\(preset.displayName) should be a modifier")
            XCTAssertNotEqual(preset.flagMask, 0)
            XCTAssertFalse(preset.displayName.isEmpty)
        }
    }
}
