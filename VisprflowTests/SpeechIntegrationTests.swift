import AVFoundation
import XCTest
@testable import Visprflow

/// End-to-end checks of the speech pipeline against audio synthesised with `say`.
///
/// This needs no microphone permission, which is what makes the transcriber testable at all on
/// a machine where the TCC dialogs cannot be answered. `say` produces cleaner speech than a
/// person in a room, so treat a pass as "the pipeline is wired correctly and the vocabulary
/// survives", not as a word-error-rate benchmark.
///
/// Opt in, because the first run downloads roughly 600 MB of Core ML models:
///     make verify-stt
/// (xcodebuild only forwards variables prefixed TEST_RUNNER_ into the test process, which is
/// what that target sets.)
final class SpeechIntegrationTests: XCTestCase {
    private static let isEnabled = ProcessInfo.processInfo.environment["VISPRFLOW_STT"] == "1"

    private var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.isEnabled, "set VISPRFLOW_STT=1 to run the speech tests")
        scratch = URL(filePath: NSTemporaryDirectory()).appending(path: "visprflow-stt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Helpers

    /// Renders `text` to an audio file with the system speech synthesiser.
    private func synthesise(_ text: String, rate: Int = 175) throws -> URL {
        let output = scratch.appending(path: "\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["-r", String(rate), "-o", output.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw XCTSkip("`say` produced no audio; no speech voice is installed")
        }
        return output
    }

    /// Words in lower case with punctuation stripped, for comparing transcripts.
    private func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Fraction of expected words that appear in the transcript, in any position.
    private func recall(expected: String, actual: String) -> Double {
        let expectedWords = words(expected)
        guard !expectedWords.isEmpty else { return 1 }
        let actualWords = Set(words(actual))
        let hits = expectedWords.filter { actualWords.contains($0) }.count
        return Double(hits) / Double(expectedWords.count)
    }

    // MARK: Tests

    func testTranscribesASpokenSentence() async throws {
        let spoken = "the login flow is broken after the token expires"
        let audio = try synthesise(spoken)
        let samples = try AudioFileLoader.samples(at: audio)

        XCTAssertGreaterThan(samples.count, Int(AudioCapture.sampleRate), "at least a second of audio")

        let transcriber = ParakeetTranscriber()
        let transcript = try await transcriber.transcribe(samples: samples, hints: .none)

        XCTAssertFalse(transcript.isEmpty, "the model returned nothing")
        let score = recall(expected: spoken, actual: transcript.text)
        XCTAssertGreaterThanOrEqual(score, 0.85, "got: \(transcript.text)")
        print("STT: '\(transcript.text)' — recall \(String(format: "%.0f%%", score * 100)), \(String(format: "%.0fx", transcript.realTimeFactor)) realtime")
    }

    func testTranscribesTechnicalVocabulary() async throws {
        // The words this app exists to get right.
        let spoken = "run git rebase on the feature branch then check the auth middleware"
        let audio = try synthesise(spoken)
        let samples = try AudioFileLoader.samples(at: audio)

        let transcript = try await ParakeetTranscriber().transcribe(samples: samples, hints: .none)
        let score = recall(expected: spoken, actual: transcript.text)
        XCTAssertGreaterThanOrEqual(score, 0.75, "got: \(transcript.text)")
        print("STT technical: '\(transcript.text)' — recall \(String(format: "%.0f%%", score * 100))")
    }

    func testMeetsTheLatencyBudgetForATenSecondUtterance() async throws {
        let spoken = String(repeating: "this is a sentence of roughly average length for dictation. ", count: 4)
        let audio = try synthesise(spoken)
        let samples = try AudioFileLoader.samples(at: audio)
        let seconds = Double(samples.count) / AudioCapture.sampleRate
        XCTAssertGreaterThan(seconds, 8, "expected a long enough utterance to be meaningful")

        let transcriber = ParakeetTranscriber()
        // Warm the model first: the plan's budget assumes it is resident.
        _ = try await transcriber.transcribe(samples: samples, hints: .none)

        let started = ContinuousClock.now
        let transcript = try await transcriber.transcribe(samples: samples, hints: .none)
        let elapsedMs = Trace.milliseconds(ContinuousClock.now - started)

        print("STT latency: \(String(format: "%.0f", elapsedMs))ms for \(String(format: "%.1f", seconds))s of audio (\(String(format: "%.0fx", transcript.realTimeFactor)) realtime)")
        // The plan budgets 80 ms for a 10 s clip. Allow generous headroom so the test reports
        // a regression rather than failing on a busy machine.
        XCTAssertLessThan(elapsedMs, 1_500, "transcription is far slower than the plan's budget")
    }

    func testRejectsAudioTooShortToBeSpeech() async throws {
        let samples = [Float](repeating: 0, count: 100)
        do {
            _ = try await ParakeetTranscriber().transcribe(samples: samples, hints: .none)
            XCTFail("expected a too-short error")
        } catch TranscriberError.audioTooShort {
            // Expected.
        }
    }

    func testSilenceDoesNotHallucinateWords() async throws {
        // Whisper is notorious for inventing text from silence. Parakeet should not.
        let samples = [Float](repeating: 0, count: Int(AudioCapture.sampleRate * 3))
        let transcript = try await ParakeetTranscriber().transcribe(samples: samples, hints: .none)
        XCTAssertTrue(transcript.isEmpty, "three seconds of silence produced: '\(transcript.text)'")
    }

    func testAudioFileLoaderResamplesToSixteenKilohertzMono() throws {
        let audio = try synthesise("resampling check")
        let file = try AVAudioFile(forReading: audio)
        XCTAssertNotEqual(file.processingFormat.sampleRate, AudioCapture.sampleRate,
                          "`say` writes 22 kHz or higher, so this exercises the converter")

        let samples = try AudioFileLoader.samples(at: audio)
        let seconds = Double(samples.count) / AudioCapture.sampleRate
        let sourceSeconds = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(seconds, sourceSeconds, accuracy: 0.1, "duration must survive resampling")
    }
}
