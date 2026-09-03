import Foundation

/// Rejects compiler output that shows one of the known failure modes.
///
/// The prompt asks the model not to answer, invent or pad. These checks assume it sometimes
/// will anyway. A rejection costs one retry at a lower edit level; the floor is inserting the
/// raw transcript, which is always safe because it is exactly what the user said.
struct Guardrails: Sendable {
    struct Verdict: Equatable, Sendable {
        var passed: Bool
        /// Why it was rejected, for the log and the history row.
        var reason: String?

        static let ok = Verdict(passed: true, reason: nil)
        static func rejected(_ reason: String) -> Verdict { Verdict(passed: false, reason: reason) }
    }

    /// Output longer than this multiple of the transcript means the model started writing prose.
    var lengthRatio: Double = 2.0
    /// Word parts shorter than this are too noisy to check for invention.
    var minimumPartLength = 3

    static let `default` = Guardrails()

    func check(output: String, transcript: String, vocabulary: [String] = []) -> Verdict {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            // Only a filler-only transcript may legitimately compile to nothing.
            return OutputChecks.wordCount(transcript) > 2
                ? .rejected("the model returned nothing")
                : .ok
        }
        if OutputChecks.looksLikeAnswer(trimmed) {
            return .rejected("the model answered instead of rewriting")
        }
        if OutputChecks.isTooLong(trimmed, comparedTo: transcript, ratio: lengthRatio) {
            return .rejected("the output is more than \(Int(lengthRatio))× the transcript")
        }
        if trimmed.contains("```"), !transcript.contains("```") {
            return .rejected("the model added a code block")
        }
        if let invented = inventedIdentifier(in: trimmed, transcript: transcript, vocabulary: vocabulary) {
            return .rejected("the model introduced “\(invented)”, which was never said")
        }
        return .ok
    }

    // MARK: Invention

    /// Finds an identifier or path in the output that the speaker never said.
    ///
    /// Two rules, because either one alone is wrong:
    ///
    /// - **Every part is a known word.** Spoken "src slash auth" legitimately becomes
    ///   `src/auth`, so a literal substring check would reject good output.
    /// - **The squashed form appears in the transcript.** Speech recognition writes compound
    ///   product names as separate lowercase words, so "can you add github actions" must let
    ///   the model produce `GitHub`. Splitting on the capital gives "git" and "hub", neither
    ///   of which was said, so rule one alone rejects half of ordinary technical vocabulary:
    ///   GitHub, TypeScript, JavaScript, iPhone, Node.js.
    ///
    /// Only when both fail is the identifier treated as invented.
    func inventedIdentifier(in output: String, transcript: String, vocabulary: [String]) -> String? {
        let known = wordSet(transcript).union(vocabulary.flatMap { wordParts($0) })
        let squashedSource = Self.squash(transcript) + " " + vocabulary.map(Self.squash).joined(separator: " ")

        for candidate in Self.identifierLikeTokens(in: output) {
            let parts = wordParts(candidate).filter { $0.count >= minimumPartLength }
            guard !parts.isEmpty else { continue }
            if parts.allSatisfy({ known.contains($0) }) { continue }

            let squashed = wordParts(candidate).joined()
            if !squashed.isEmpty, squashedSource.contains(squashed) { continue }

            return candidate
        }
        return nil
    }

    /// Lowercased text with every separator removed, so "type script" and "TypeScript" match.
    static func squash(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Tokens that look like code rather than prose: paths, dotted names, snake_case,
    /// camelCase, and anything in backticks.
    static func identifierLikeTokens(in text: String) -> [String] {
        var found: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            // Strip sentence punctuation and wrapping characters, keeping internal structure.
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]{}<>,;:!?"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard token.count >= 3 else { continue }
            guard token.rangeOfCharacter(from: .letters) != nil else { continue }
            if looksLikeIdentifier(token) {
                found.append(token)
            }
        }
        return found
    }

    private static func looksLikeIdentifier(_ token: String) -> Bool {
        // A path: a slash with word characters on both sides.
        if token.contains("/"), token.first != "/", !token.hasPrefix("http") { return true }
        if token.contains("_") { return true }
        // A dotted name such as config.yaml or utils.parseDate, but not a decimal number.
        if token.contains("."), token.rangeOfCharacter(from: .letters) != nil,
           !token.hasSuffix("."), token.split(separator: ".").count >= 2 { return true }
        // camelCase or PascalCase with an internal capital.
        let characters = Array(token)
        for index in 1..<characters.count where characters[index].isUppercase && characters[index - 1].isLowercase {
            return true
        }
        return false
    }

    /// Lowercased word parts of a token, splitting on separators and camelCase boundaries.
    func wordParts(_ token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character?
        for character in token {
            if character.isLetter || character.isNumber {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    parts.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                parts.append(current.lowercased())
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { parts.append(current.lowercased()) }
        return parts
    }

    /// Every word in a piece of text, lowercased, including the parts of compound tokens.
    private func wordSet(_ text: String) -> Set<String> {
        var words = Set<String>()
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            for part in wordParts(String(token)) {
                words.insert(part)
            }
        }
        return words
    }
}
