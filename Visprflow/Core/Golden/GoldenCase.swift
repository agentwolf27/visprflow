import Foundation

/// One entry in the golden set: a messy transcript and the output the compiler must produce.
/// Fixtures live in `Fixtures/golden/*.json`; the test target validates them and phase 2 runs
/// the compiler against them on every prompt change.
struct GoldenCase: Codable, Equatable, Identifiable, Sendable {
    enum Destination: String, Codable, Sendable {
        case claudeCode = "claude_code"
        case cursor
        case codex
        case chat
        case message
        case email
        case document
        case shell
    }

    enum Level: String, Codable, Sendable {
        case verbatim = "VERBATIM"
        case light = "LIGHT"
        case medium = "MEDIUM"
        case full = "FULL"
    }

    var id: String
    var destination: Destination
    var level: Level
    var transcript: String
    var expected: String
    /// Terms that must survive the rewrite spelled exactly this way (identifiers, paths, names).
    var mustContain: [String] = []
    var notes: String?

    /// Swift's synthesised `Decodable` does not fall back to a property's default value, so a
    /// fixture written without `mustContain` would fail to decode with a confusing error.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        destination = try container.decode(Destination.self, forKey: .destination)
        level = try container.decode(Level.self, forKey: .level)
        transcript = try container.decode(String.self, forKey: .transcript)
        expected = try container.decode(String.self, forKey: .expected)
        mustContain = try container.decodeIfPresent([String].self, forKey: .mustContain) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    static func loadAll(from directory: URL) throws -> [GoldenCase] {
        let decoder = JSONDecoder()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try decoder.decode(GoldenCase.self, from: Data(contentsOf: $0)) }
    }
}

/// Mechanical checks that any compiler output must pass before it is ever inserted.
/// These are the cheap half of the phase 2 guardrails; the model-side half lives in the prompt.
enum OutputChecks {
    /// Interjections that only read as the assistant reflex when punctuation follows them.
    /// Bare prefix matching is wrong here: "Sure looks like a race condition" and "Certainly
    /// worth checking the index" are things a person dictates, and rejecting them would send
    /// good output to the raw-transcript fallback.
    private static let interjections = [
        "sure", "certainly", "of course", "absolutely", "got it", "okay", "ok", "understood",
    ]

    /// Refusals. These are unambiguous however the sentence continues.
    private static let refusalPrefixes = [
        "i can't", "i cannot", "i won't", "i am unable", "i'm unable", "i'd be happy",
        "i would be happy", "great question", "as an ai",
    ]

    /// Phrases where the model talks *about* the text instead of producing it.
    private static let metaPhrases = [
        "here's the rewritten", "here is the rewritten", "here's the cleaned",
        "here is the cleaned", "here's the corrected", "here is the corrected",
        "here's the polished", "here is the polished", "here's your", "here is your",
        "the rewritten text", "the cleaned-up version", "the corrected version",
        "rewritten prompt:", "cleaned transcript:",
    ]

    /// True when the output looks like the model answered the user instead of rewriting them.
    static func looksLikeAnswer(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }

        if refusalPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }

        // Only the opening of the text can carry the reflex, so bound the meta-phrase scan.
        let opening = String(trimmed.prefix(60))
        if metaPhrases.contains(where: { opening.contains($0) }) { return true }

        // An interjection counts only when punctuation closes it off: "Sure," or "Okay:".
        for word in interjections where trimmed.hasPrefix(word) {
            let rest = trimmed.dropFirst(word.count)
            if let next = rest.first, ",!:.".contains(next) { return true }
            if rest.isEmpty { return true }
        }
        return false
    }

    /// True when the output is more than `ratio` times the transcript's word count.
    static func isTooLong(_ output: String, comparedTo transcript: String, ratio: Double = 2.0) -> Bool {
        let outWords = wordCount(output)
        let inWords = max(wordCount(transcript), 1)
        return Double(outWords) > Double(inWords) * ratio
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
