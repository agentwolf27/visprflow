import Foundation

/// Notices when the trigger key is firing because the user is typing, rather than because they
/// want to dictate.
///
/// Static suitability rules catch the obvious cases, but they cannot cover every keyboard: a key
/// that is spare on one layout is load-bearing on another, and remapping tools move things
/// around. The behaviour is unmistakable though — a burst of very short captures in quick
/// succession is someone typing, not someone talking. Choosing Left Shift produced exactly that
/// pattern and the app said nothing; this is the check that would have caught it in seconds.
struct TriggerHealth: Sendable {
    /// A capture shorter than this was not speech.
    static let shortCapture: TimeInterval = 0.3
    /// How many short captures within the window count as a problem.
    static let burstCount = 5
    /// The window those captures have to fall inside.
    static let window: TimeInterval = 10

    private(set) var recentShortCaptures: [TimeInterval] = []
    /// Set once a burst is seen, so the warning is raised a single time per run.
    private(set) var hasWarned = false

    /// Records a finished capture. Returns true when this one completes a burst worth warning
    /// about.
    mutating func record(duration: TimeInterval, at now: TimeInterval) -> Bool {
        guard duration < Self.shortCapture else {
            // A real dictation means the key is being used deliberately; forget the noise.
            recentShortCaptures.removeAll()
            return false
        }

        recentShortCaptures.append(now)
        recentShortCaptures.removeAll { now - $0 > Self.window }

        guard recentShortCaptures.count >= Self.burstCount, !hasWarned else { return false }
        hasWarned = true
        return true
    }

    /// Called when the user changes the trigger, so the next key starts with a clean record.
    mutating func reset() {
        recentShortCaptures.removeAll()
        hasWarned = false
    }

    func message(for key: TriggerKey) -> String {
        "\(key.displayName) is firing while you type. Choose a different trigger key."
    }
}
