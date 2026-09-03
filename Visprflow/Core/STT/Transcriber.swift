import Foundation

/// Result of turning audio into words.
struct Transcript: Equatable, Sendable {
    var text: String
    var confidence: Float
    /// Length of the audio in seconds.
    var audioDuration: TimeInterval
    /// Wall-clock time the model took.
    var processingTime: TimeInterval

    /// Multiple of real time. 10 s of audio transcribed in 0.1 s is 100x.
    var realTimeFactor: Double {
        processingTime > 0 ? audioDuration / processingTime : 0
    }

    static let empty = Transcript(text: "", confidence: 0, audioDuration: 0, processingTime: 0)

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Terms that should bias recognition, harvested from the workspace in phase 3.
struct TranscriptionHints: Equatable, Sendable {
    var vocabulary: [String] = []
    static let none = TranscriptionHints()
}

/// Anything that turns 16 kHz mono Float32 samples into text.
///
/// Phase 1 ships the local Parakeet engine. Phase 4 adds streaming cloud engines behind the
/// same protocol, so the pipeline above it never changes.
protocol Transcriber: Sendable {
    /// Stable identifier for logs and settings.
    var id: String { get }
    /// Human-readable name for the setup window.
    var displayName: String { get }
    /// Downloads and loads models. Safe to call repeatedly; later calls are cheap.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    func isReady() async -> Bool
    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> Transcript
}

extension Transcriber {
    func prepare() async throws {
        try await prepare(progress: nil)
    }
}

enum TranscriberError: Error, LocalizedError {
    case notReady
    case audioTooShort
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "The speech model is still loading."
        case .audioTooShort: "That was too short to transcribe."
        case let .underlying(message): message
        }
    }
}
