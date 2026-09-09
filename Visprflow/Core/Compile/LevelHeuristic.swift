import Foundation

/// Chooses how much the compiler may change what was said.
///
/// The research on rewriting spoken text is consistent: over-editing is the common failure, so
/// the rule is to pick the lowest level that does the job. Short utterances and messages get
/// cleanup only; a long request to a coding agent earns a full restructure.
enum LevelHeuristic {
    struct Decision: Equatable, Sendable {
        var level: EditLevel
        /// Transcript with any spoken level command removed.
        var transcript: String
        /// Why this level was chosen, shown in the HUD and stored in history.
        var reason: String
    }

    /// Utterances shorter than this are cleaned up, never restructured.
    static let shortUtteranceWords = 25

    static func decide(
        transcript: String,
        destination: Destination,
        override: EditLevel? = nil
    ) -> Decision {
        let spoken = spokenCommand(in: transcript)
        let text = spoken?.remainder ?? transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if let override {
            return Decision(level: override, transcript: text, reason: "you asked for it")
        }
        if let spoken {
            return Decision(level: spoken.level, transcript: text, reason: "you said “\(spoken.phrase)”")
        }
        if destination.defaultLevel == .verbatim {
            return Decision(level: .verbatim, transcript: text, reason: "\(destination.displayName) takes text as spoken")
        }

        let words = OutputChecks.wordCount(text)
        if words < shortUtteranceWords {
            let level = min(destination.defaultLevel, .light)
            return Decision(level: level, transcript: text, reason: "short utterance")
        }
        if words >= destination.fullLevelWordThreshold {
            return Decision(level: .full, transcript: text, reason: "long request to \(destination.displayName)")
        }
        // A destination that defaults to full still only gets there past its threshold.
        let level = min(destination.defaultLevel, .medium)
        return Decision(level: level, transcript: text, reason: destination.displayName.lowercased())
    }

    // MARK: Spoken commands

    struct SpokenCommand: Equatable, Sendable {
        var level: EditLevel
        var phrase: String
        var remainder: String
    }

    /// Phrases that set the level explicitly, longest first so "prompt mode" wins over "prompt".
    private static let commands: [(phrase: String, level: EditLevel)] = [
        ("prompt mode", .full),
        ("prompt engineer", .full),
        ("compile this", .full),
        ("clean this up", .light),
        ("verbatim", .verbatim),
        ("exactly", .verbatim),
    ]

    /// Finds a level command at the very start of the transcript and strips it.
    /// Only the opening counts: "say verbatim to the team" is content, not a command.
    static func spokenCommand(in transcript: String) -> SpokenCommand? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        for (phrase, level) in commands where lowered.hasPrefix(phrase) {
            let rest = trimmed.dropFirst(phrase.count)
            // A command has to be closed off by punctuation or a space, otherwise
            // "exactly right" would be read as a command. And a phrase with nothing after
            // it is dictation, not an instruction: obeying it would insert nothing at all.
            guard let separator = rest.first, ",:. ".contains(separator) else { continue }

            let remainder = rest
                .drop { ",:. ".contains($0) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A bare command with nothing after it is almost certainly dictation, not an
            // instruction: there would be nothing left to insert.
            guard !remainder.isEmpty else { continue }
            return SpokenCommand(level: level, phrase: phrase, remainder: remainder)
        }
        return nil
    }
}
