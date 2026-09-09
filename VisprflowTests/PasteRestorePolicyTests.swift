import XCTest
@testable import Visprflow

final class PasteRestorePolicyTests: XCTestCase {
    private let policy = PasteRestorePolicy(receiptTimeout: 0.8, quietPeriod: 0.2, maximumWait: 3.0)

    func testWaitsWhileNoReceiptAndInsideTimeout() {
        XCTAssertEqual(
            policy.decide(elapsed: 0.1, lastReceipt: nil, pasteboardChanged: false),
            .wait(policy.pollInterval)
        )
    }

    func testRestoresWhenNothingEverReadTheData() {
        // An app that never pasted: give the clipboard back rather than hold it forever.
        XCTAssertEqual(
            policy.decide(elapsed: 0.85, lastReceipt: nil, pasteboardChanged: false),
            .restore
        )
    }

    func testWaitsBrieflyAfterAReceipt() {
        // Chromium probes several types before reading, so a receipt is not the end.
        XCTAssertEqual(
            policy.decide(elapsed: 0.3, lastReceipt: 0.05, pasteboardChanged: false),
            .wait(policy.pollInterval)
        )
    }

    func testRestoresOnceTheQuietPeriodPasses() {
        XCTAssertEqual(
            policy.decide(elapsed: 0.5, lastReceipt: 0.25, pasteboardChanged: false),
            .restore
        )
    }

    func testAbandonsWhenSomeoneElseWroteToThePasteboard() {
        // The user copied something while we were waiting. Their copy wins.
        XCTAssertEqual(
            policy.decide(elapsed: 0.2, lastReceipt: 0.01, pasteboardChanged: true),
            .abandon
        )
    }

    func testAbandonTakesPrecedenceOverEveryOtherOutcome() {
        XCTAssertEqual(policy.decide(elapsed: 99, lastReceipt: 99, pasteboardChanged: true), .abandon)
    }

    func testMaximumWaitAlwaysEndsTheLoop() {
        // A pathological app keeps reading forever; the ceiling still returns the clipboard.
        XCTAssertEqual(
            policy.decide(elapsed: 3.0, lastReceipt: 0.0, pasteboardChanged: false),
            .restore
        )
    }

    func testLoopTerminatesForEveryReceiptPattern() {
        // Simulate the wait loop and prove it always finishes well inside the ceiling.
        for receiptEvery in [0.0, 0.05, 0.1, 0.19] {
            var elapsed = 0.0
            var lastReceipt: TimeInterval? = nil
            var iterations = 0
            loop: while iterations < 200 {
                iterations += 1
                switch policy.decide(elapsed: elapsed, lastReceipt: lastReceipt, pasteboardChanged: false) {
                case let .wait(interval):
                    elapsed += interval
                    // A reader that keeps touching the pasteboard at this cadence.
                    lastReceipt = receiptEvery < interval ? 0 : (lastReceipt ?? 0) + interval
                case .restore, .abandon:
                    break loop
                }
            }
            XCTAssertLessThanOrEqual(elapsed, policy.maximumWait + policy.pollInterval,
                                     "receipts every \(receiptEvery)s should still terminate")
            XCTAssertLessThan(iterations, 200, "the wait loop must not spin forever")
        }
    }
}
