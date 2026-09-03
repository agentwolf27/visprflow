import Foundation

/// Deterministic cleanup that runs on this Mac in microseconds, with no model behind it.
///
/// Most of what a LIGHT edit does is mechanical: drop the "um"s, collapse a stutter, turn
/// spoken punctuation into symbols, capitalise the sentence. None of that needs a language
/// model, and doing it locally means the common path is instant, free, works offline, and
/// costs nothing against a subscription.
///
/// What it deliberately does *not* attempt is self-correction. "no wait, the token refresh not
/// the session refresh" needs judgement about which half to keep, and getting that wrong
/// silently changes what the user meant. `needsModel` detects those and hands them upward.
enum LocalCleanup {
    /// Sounds that are never words. Discourse markers such as "like" and "actually" are
    /// deliberately absent: they carry meaning often enough that removing them is a
    /// meaning change, not a cleanup.
    static let fillers: Set<String> = [
        "um", "uhm", "uh", "erm", "er", "ah", "eh", "hmm", "hm", "mm", "mmm", "mhm", "uhh", "umm",
    ]

    /// Phrases that signal the speaker replaced something they just said. A transcript
    /// containing one of these needs a model to resolve, so local cleanup steps aside.
    static let correctionSignals: [String] = [
        "scratch that", "no wait", "wait no", "i mean", "or rather", "strike that",
        "let me rephrase", "actually no", "no sorry", "sorry i meant", "rather than that",
    ]

    /// Spoken punctuation, applied only when the word stands alone.
    static let spokenPunctuation: [String: String] = [
        "period": ".", "full stop": ".", "comma": ",", "question mark": "?",
        "exclamation mark": "!", "exclamation point": "!", "colon": ":", "semicolon": ";",
    ]

    /// True when the transcript contains something only a model should resolve.
    static func needsModel(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        return correctionSignals.contains { lowered.contains($0) }
    }

    /// Cleans a transcript. Word order and wording are preserved exactly; only disfluencies,
    /// repeats, spoken punctuation and casing change.
    static func clean(_ transcript: String) -> String {
        var words = transcript
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        words = removeFillers(from: words)
        words = collapseRepeats(in: words)

        var text = words.joined(separator: " ")
        text = applySpokenLayout(to: text)
        text = applySpokenPunctuation(to: text)
        text = tidySpacing(in: text)
        text = capitaliseSentences(in: text)
        return addTerminalPunctuation(to: text)
    }

    // MARK: Steps

    static func removeFillers(from words: [String]) -> [String] {
        words.filter { word in
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return !fillers.contains(bare)
        }
    }

    /// "the the file" becomes "the file". Only exact adjacent repeats, and never for words a
    /// speaker legitimately doubles.
    static func collapseRepeats(in words: [String]) -> [String] {
        let legitimate: Set<String> = ["had", "that", "very", "really", "no", "yes", "ha"]
        var result: [String] = []
        for word in words {
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if let previous = result.last?.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted),
               previous == bare, !legitimate.contains(bare), !bare.isEmpty {
                continue
            }
            result.append(word)
        }
        return result
    }

    /// "new paragraph" and "new line" become real breaks.
    static func applySpokenLayout(to text: String) -> String {
        var result = text
        for (phrase, replacement) in [("new paragraph", "\n\n"), ("new line", "\n")] {
            result = result.replacingOccurrences(
                of: "\\b\(phrase)\\b",
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// A standalone "comma" or "period" becomes the symbol, attached to the previous word.
    static func applySpokenPunctuation(to text: String) -> String {
        var result = text
        for (word, symbol) in spokenPunctuation {
            result = result.replacingOccurrences(
                of: "\\s+\(word)\\b",
                with: symbol,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    static func tidySpacing(in text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([.,!?;:])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\n ", with: "\n")
            .replacingOccurrences(of: " \n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Capitalises the first letter of the text and of each sentence, and the word "I".
    static func capitaliseSentences(in text: String) -> String {
        var characters = Array(text)
        var capitaliseNext = true
        for index in characters.indices {
            let character = characters[index]
            if capitaliseNext, character.isLetter {
                characters[index] = Character(character.uppercased())
                capitaliseNext = false
            } else if ".!?".contains(character) || character == "\n" {
                capitaliseNext = true
            }
        }
        var result = String(characters)
        // The pronoun "I", which speech recognition often leaves lowercase.
        result = result.replacingOccurrences(
            of: "\\bi\\b",
            with: "I",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\bi'",
            with: "I'",
            options: .regularExpression
        )
        return result
    }

    /// Ends the text with a full stop when it has no terminal punctuation and reads as prose.
    static func addTerminalPunctuation(to text: String) -> String {
        guard let last = text.last else { return text }
        guard last.isLetter || last.isNumber else { return text }
        // Anything that looks like a command or a path is left exactly as it is.
        guard !text.contains("/"), !text.contains("--"), !text.contains("```") else { return text }
        return text + (startsAQuestion(text) ? "?" : ".")
    }

    /// Whether the text opens with a question word, so it should end with a question mark.
    static func startsAQuestion(_ text: String) -> Bool {
        let openers = [
            "what", "why", "how", "when", "where", "who", "which", "can you", "could you",
            "would you", "should we", "do you", "did you", "is it", "are we", "should i",
        ]
        let lowered = text.lowercased()
        return openers.contains { lowered.hasPrefix($0 + " ") }
    }
}

/// A `TextGenerating` that never leaves the machine.
///
/// Used for the LIGHT level so the most common dictation costs nothing and appears instantly.
/// It refuses anything it should not attempt, so the caller can fall back to a real model.
struct LocalGenerator: TextGenerating {
    func generate(
        _ request: GenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // The transcript is the last tagged block of the user message.
        guard let transcript = Self.transcript(in: request.user) else {
            throw GenerationError.emptyResponse
        }
        let cleaned = LocalCleanup.clean(transcript)
        onDelta(cleaned)
        return cleaned
    }

    /// Pulls the transcript back out of the composed user message.
    static func transcript(in userMessage: String) -> String? {
        guard let start = userMessage.range(of: "<transcript>"),
              let end = userMessage.range(of: "</transcript>")
        else { return nil }
        return String(userMessage[start.upperBound..<end.lowerBound])
    }
}
