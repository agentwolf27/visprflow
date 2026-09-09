import Foundation

/// Decides when it is safe to put the user's clipboard back after a paste.
///
/// Restoring on a fixed timer is what makes competing dictation apps paste stale clipboard
/// contents: restore too early and the target app reads the old value, too late and the user's
/// own copy is clobbered. Instead the pasteboard is published as a promise, and the target app
/// asking for the data is a *receipt* that the paste really happened. After the last receipt we
/// wait a short quiet period, because Chromium-based apps probe several types before reading.
struct PasteRestorePolicy: Sendable, Equatable {
    /// How long to wait for the first receipt before giving up and restoring anyway.
    var receiptTimeout: TimeInterval = 0.8
    /// Silence required after the last receipt before restoring.
    var quietPeriod: TimeInterval = 0.2
    /// Hard ceiling so a pathological app can never keep the clipboard hostage.
    var maximumWait: TimeInterval = 3.0

    static let `default` = PasteRestorePolicy()

    enum Decision: Equatable, Sendable {
        /// Keep waiting; check again after this interval.
        case wait(TimeInterval)
        /// Put the user's clipboard back.
        case restore
        /// Someone else wrote to the pasteboard; their content wins and we leave it alone.
        case abandon
    }

    /// - Parameters:
    ///   - elapsed: time since the paste keystroke was posted.
    ///   - lastReceipt: time since the most recent read of our data, or nil if never read.
    ///   - pasteboardChanged: true when the change count no longer matches what we wrote.
    func decide(elapsed: TimeInterval, lastReceipt: TimeInterval?, pasteboardChanged: Bool) -> Decision {
        if pasteboardChanged {
            return .abandon
        }
        if elapsed >= maximumWait {
            return .restore
        }
        guard let lastReceipt else {
            // Nothing has read our data yet.
            return elapsed >= receiptTimeout ? .restore : .wait(pollInterval)
        }
        return lastReceipt >= quietPeriod ? .restore : .wait(pollInterval)
    }

    /// How often to re-evaluate while waiting.
    var pollInterval: TimeInterval { 0.05 }
}
