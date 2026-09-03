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
    static let answerPrefixes = [
        "sure", "here's", "here is", "of course", "certainly", "i can't", "i cannot",
        "i'd be happy", "great question", "okay, here", "the rewritten",
    ]

    /// True when the output looks like the model answered the user instead of rewriting them.
    static func looksLikeAnswer(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answerPrefixes.contains { trimmed.hasPrefix($0) }
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
