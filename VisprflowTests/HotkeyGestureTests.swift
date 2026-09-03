import XCTest
@testable import Visprflow

final class HotkeyGestureTests: XCTestCase {
    private func makeGesture(mode: HotkeyMode = .hybrid) -> HotkeyGesture {
        HotkeyGesture(config: .init(mode: mode, minimumPress: 0.3, doubleTapWindow: 0.4))
    }

    // MARK: Hold to talk

    func testHoldLongEnoughCapturesAndFinishes() {
        var g = makeGesture()
        XCTAssertEqual(g.handle(.triggerDown(at: 0, modifiers: .none)), .startCapture)
        XCTAssertTrue(g.isRecording)
        XCTAssertEqual(g.handle(.triggerUp(at: 1.2, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: false))
        XCTAssertFalse(g.isRecording)
    }

    func testShortTapIsDiscarded() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerUp(at: 0.1, modifiers: .none)),
                       .discardCapture(reason: .tooShort))
        XCTAssertFalse(g.isRecording)
    }

    func testPressExactlyAtThresholdCounts() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerUp(at: 0.3, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: false))
    }

    func testModifiersAreReportedAtRelease() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        // Shift was added after the key went down; the release is what counts.
        XCTAssertEqual(g.handle(.triggerUp(at: 1, modifiers: .shift)),
                       .finishCapture(modifiers: .shift, locked: false))
    }

    func testAutoRepeatDownsAreIgnored() {
        var g = makeGesture()
        XCTAssertEqual(g.handle(.triggerDown(at: 0, modifiers: .none)), .startCapture)
        XCTAssertEqual(g.handle(.triggerDown(at: 0.1, modifiers: .none)), .none)
        XCTAssertEqual(g.handle(.triggerDown(at: 0.2, modifiers: .none)), .none)
        XCTAssertEqual(g.handle(.triggerUp(at: 1, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: false))
    }

    func testStrayKeyUpWhenIdleDoesNothing() {
        var g = makeGesture()
        XCTAssertEqual(g.handle(.triggerUp(at: 1, modifiers: .none)), .none)
        XCTAssertFalse(g.isRecording)
    }

    // MARK: Double-tap to lock

    func testDoubleTapLocksHandsFreeAndNextPressFinishes() {
        var g = makeGesture()
        // First tap: too short, discarded, but it arms the double-tap window.
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerUp(at: 0.1, modifiers: .none)),
                       .discardCapture(reason: .tooShort))
        // Second tap inside the window: starts capture and locks on release.
        XCTAssertEqual(g.handle(.triggerDown(at: 0.3, modifiers: .none)), .startCapture)
        XCTAssertEqual(g.handle(.triggerUp(at: 0.35, modifiers: .none)), .lockedOn)
        XCTAssertTrue(g.isRecording)
        XCTAssertTrue(g.isLocked)
        // A later press ends the session on release.
        XCTAssertEqual(g.handle(.triggerDown(at: 5, modifiers: .none)), .none)
        XCTAssertTrue(g.isRecording, "still recording until the key comes back up")
        XCTAssertEqual(g.handle(.triggerUp(at: 5.05, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: true))
        XCTAssertFalse(g.isRecording)
    }

    func testSecondTapOutsideWindowIsJustAnotherHold() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.1, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerDown(at: 0.9, modifiers: .none)), .startCapture)
        XCTAssertFalse(g.isLocked)
        XCTAssertEqual(g.handle(.triggerUp(at: 2.0, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: false))
    }

    func testLongPressDoesNotArmDoubleTap() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 1.0, modifiers: .none))
        // A press right after a *long* press is a normal hold, not a lock.
        XCTAssertEqual(g.handle(.triggerDown(at: 1.1, modifiers: .none)), .startCapture)
        XCTAssertFalse(g.isLocked)
    }

    func testThreeShortTapsDoNotDoubleLock() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.1, modifiers: .none))
        _ = g.handle(.triggerDown(at: 0.2, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerUp(at: 0.25, modifiers: .none)), .lockedOn)
        // The third tap stops the locked session rather than re-locking.
        _ = g.handle(.triggerDown(at: 0.4, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerUp(at: 0.45, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: true))
        XCTAssertFalse(g.isRecording)
    }

    func testSilenceTimeoutEndsLockedSession() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.1, modifiers: .none))
        _ = g.handle(.triggerDown(at: 0.3, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.35, modifiers: .none))
        XCTAssertEqual(g.handle(.silenceTimeout), .finishCapture(modifiers: .none, locked: true))
        XCTAssertFalse(g.isRecording)
    }

    func testSilenceTimeoutIgnoredWhenNotLocked() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        XCTAssertEqual(g.handle(.silenceTimeout), .none, "holding the key means the user decides when to stop")
        XCTAssertTrue(g.isRecording)
    }

    // MARK: Cancelling

    func testEscapeCancelsWhileHolding() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        XCTAssertEqual(g.handle(.escape), .discardCapture(reason: .escape))
        XCTAssertFalse(g.isRecording)
    }

    func testEscapeCancelsWhileLocked() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.1, modifiers: .none))
        _ = g.handle(.triggerDown(at: 0.3, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.35, modifiers: .none))
        XCTAssertEqual(g.handle(.escape), .discardCapture(reason: .escape))
        XCTAssertFalse(g.isRecording)
    }

    func testEscapeWhenIdleDoesNothing() {
        var g = makeGesture()
        XCTAssertEqual(g.handle(.escape), .none)
    }

    func testEscapeClearsDoubleTapArming() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.1, modifiers: .none))  // arms the window
        _ = g.handle(.triggerDown(at: 0.2, modifiers: .none))
        _ = g.handle(.escape)
        // After a cancel, the next press is a plain hold rather than a lock.
        XCTAssertEqual(g.handle(.triggerDown(at: 0.3, modifiers: .none)), .startCapture)
        XCTAssertFalse(g.isLocked)
    }

    func testResynchroniseDiscardsInFlightGesture() {
        var g = makeGesture()
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        XCTAssertEqual(g.handle(.resynchronise), .discardCapture(reason: .resynchronise))
        XCTAssertFalse(g.isRecording)
        XCTAssertEqual(g.handle(.resynchronise), .none, "nothing to discard when idle")
    }

    // MARK: Modes

    func testPushToTalkModeNeverLocks() {
        var g = makeGesture(mode: .pushToTalk)
        _ = g.handle(.triggerDown(at: 0, modifiers: .none))
        _ = g.handle(.triggerUp(at: 0.1, modifiers: .none))
        XCTAssertEqual(g.handle(.triggerDown(at: 0.2, modifiers: .none)), .startCapture)
        XCTAssertFalse(g.isLocked, "push-to-talk ignores the double-tap window")
    }

    func testToggleModeStartsAndStopsOnAlternatePresses() {
        var g = makeGesture(mode: .toggle)
        XCTAssertEqual(g.handle(.triggerDown(at: 0, modifiers: .none)), .startCapture)
        XCTAssertEqual(g.handle(.triggerUp(at: 0.05, modifiers: .none)), .lockedOn)
        XCTAssertTrue(g.isRecording, "a toggle keeps recording after the key is released")
        XCTAssertEqual(g.handle(.triggerDown(at: 3, modifiers: .none)), .none)
        XCTAssertEqual(g.handle(.triggerUp(at: 3.05, modifiers: .none)),
                       .finishCapture(modifiers: .none, locked: true))
        XCTAssertFalse(g.isRecording)
    }

    // MARK: Sequences

    func testTwoConsecutiveDictations() {
        var g = makeGesture()
        for start in [0.0, 10.0] {
            XCTAssertEqual(g.handle(.triggerDown(at: start, modifiers: .none)), .startCapture)
            XCTAssertEqual(g.handle(.triggerUp(at: start + 2, modifiers: .none)),
                           .finishCapture(modifiers: .none, locked: false))
        }
        XCTAssertFalse(g.isRecording)
    }
}
