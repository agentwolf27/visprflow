import XCTest
@testable import Visprflow

final class TriggerHealthTests: XCTestCase {
    /// The scenario this exists for: someone picks Left Shift, then types a sentence with
    /// capitals. Each capital is a sub-300ms "capture". The app should notice and say so.
    func testBurstOfShortCapturesWarns() {
        var health = TriggerHealth()
        var warned = false
        // Five capitals typed over two seconds.
        for index in 0..<5 {
            warned = health.record(duration: 0.05, at: Double(index) * 0.4)
        }
        XCTAssertTrue(warned, "five short captures in two seconds is typing, not dictating")
    }

    func testWarnsOnlyOnce() {
        var health = TriggerHealth()
        for index in 0..<5 { _ = health.record(duration: 0.05, at: Double(index) * 0.4) }
        let again = health.record(duration: 0.05, at: 2.4)
        XCTAssertFalse(again, "the warning is raised once, not on every keystroke after it")
    }

    func testShortCapturesSpreadOutDoNotWarn() {
        var health = TriggerHealth()
        var warned = false
        // One accidental tap every 30 seconds is not a broken trigger key.
        for index in 0..<8 {
            warned = health.record(duration: 0.1, at: Double(index) * 30)
        }
        XCTAssertFalse(warned, "occasional stray taps are normal")
    }

    func testARealDictationClearsSuspicion() {
        var health = TriggerHealth()
        for index in 0..<4 { _ = health.record(duration: 0.05, at: Double(index) * 0.3) }
        // A genuine dictation means the key is being used on purpose.
        _ = health.record(duration: 4.0, at: 1.5)
        XCTAssertTrue(health.recentShortCaptures.isEmpty)

        var warned = false
        for index in 0..<4 {
            warned = health.record(duration: 0.05, at: 2.0 + Double(index) * 0.2)
        }
        XCTAssertFalse(warned, "the count restarted, so four more taps is not yet a burst")
    }

    func testLongCapturesNeverWarn() {
        var health = TriggerHealth()
        var warned = false
        for index in 0..<10 {
            warned = health.record(duration: 2.0, at: Double(index) * 0.5)
        }
        XCTAssertFalse(warned, "these are dictations, however rapid")
    }

    func testResetClearsTheWarning() {
        var health = TriggerHealth()
        for index in 0..<5 { _ = health.record(duration: 0.05, at: Double(index) * 0.4) }
        XCTAssertTrue(health.hasWarned)

        // Changing the key gives the new one a clean record.
        health.reset()
        XCTAssertFalse(health.hasWarned)
        XCTAssertTrue(health.recentShortCaptures.isEmpty)

        var warned = false
        for index in 0..<5 { warned = health.record(duration: 0.05, at: 10 + Double(index) * 0.4) }
        XCTAssertTrue(warned, "a fresh key can raise its own warning")
    }

    func testMessageNamesTheKeySoItIsActionable() {
        let health = TriggerHealth()
        let message = health.message(for: .rightOption)
        XCTAssertTrue(message.contains("Right Option"), message)
    }
}
