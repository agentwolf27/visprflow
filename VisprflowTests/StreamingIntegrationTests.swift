import AVFoundation
import XCTest
@testable import Visprflow

/// Exercises the streaming transcriber against real speech, fed in small chunks the way the
/// audio tap delivers it. Opt in with `make verify-streaming`; the first run downloads the
/// streaming model.
final class StreamingIntegrationTests: XCTestCase {
    private static let isEnabled = ProcessInfo.processInfo.environment["VISPRFLOW_STT"] == "1"
    private var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.isEnabled, "set VISPRFLOW_STT=1 to run the streaming tests")
        scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Helpers

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

    /// Reads a file as the 16 kHz mono Float32 the pipeline uses.
    private func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw XCTSkip("no converter for the synthesised format")
        }
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 4096
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try? file.read(into: input)
            status.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        let channel = output.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func recall(expected: String, actual: String) -> Double {
        let expectedWords = words(expected)
        guard !expectedWords.isEmpty else { return 1 }
        let actualWords = Set(words(actual))
        return Double(expectedWords.filter { actualWords.contains($0) }.count) / Double(expectedWords.count)
    }

    // MARK: Tests

    /// The core claim: feeding audio in as it is spoken produces partial text along the way and
    /// a correct transcript at the end.
    func testProducesPartialsWhileSpeakingAndAFinalTranscript() async throws {
        let spoken = "the login flow is broken after the token expires so write a failing test first"
        let audio = try samples(of: try synthesise(spoken))
        XCTAssertGreaterThan(audio.count, Int(AudioCapture.sampleRate), "expected over a second of speech")

        let streaming = StreamingTranscriber()
        let manager = try await streaming.prepare()
        try await manager.reset()

        let partials = PartialRecorder()
        await manager.setPartialTranscriptCallback { partials.record($0) }

        // 320 ms at a time, the same granularity the tap delivers at.
        let chunk = Int(AudioCapture.sampleRate * 0.32)
        var index = 0
        let started = ContinuousClock.now
        while index < audio.count {
            let end = min(index + chunk, audio.count)
            let slice = Array(audio[index..<end])
            try await manager.appendAudio(StreamingIntegrationTests.buffer(slice))
            try await manager.processBufferedAudio()
            index = end
        }
        let final = try await manager.finish()
        let elapsed = Trace.milliseconds(ContinuousClock.now - started) / 1000

        print("STREAMING: \(String(format: "%.2f", elapsed))s -> \(final)")
        print("STREAMING partials seen: \(partials.count)")

        XCTAssertFalse(final.trimmingCharacters(in: .whitespaces).isEmpty, "a transcript is produced")
        let score = recall(expected: spoken, actual: final)
        XCTAssertGreaterThan(score, 0.7, "recall was \(score) for: \(final)")
        XCTAssertGreaterThan(partials.count, 0, "partial text should arrive before the end")
    }

    /// The tail matters: the last words are the ones a naive implementation drops.
    func testFinalTranscriptIncludesTheEndOfTheUtterance() async throws {
        let spoken = "check the retry logic and then deploy to staging"
        let audio = try samples(of: try synthesise(spoken))

        let streaming = StreamingTranscriber()
        let manager = try await streaming.prepare()
        try await manager.reset()

        let chunk = Int(AudioCapture.sampleRate * 0.32)
        var index = 0
        while index < audio.count {
            let end = min(index + chunk, audio.count)
            try await manager.appendAudio(StreamingIntegrationTests.buffer(Array(audio[index..<end])))
            try await manager.processBufferedAudio()
            index = end
        }
        let final = try await manager.finish().lowercased()
        print("STREAMING tail: \(final)")
        XCTAssertTrue(final.contains("staging"), "the last word survived: \(final)")
    }

    func testResetAllowsASecondDictation() async throws {
        let streaming = StreamingTranscriber()
        let manager = try await streaming.prepare()

        for phrase in ["first message about the parser", "second message about the cache"] {
            try await manager.reset()
            let audio = try samples(of: try synthesise(phrase))
            try await manager.appendAudio(StreamingIntegrationTests.buffer(audio))
            try await manager.processBufferedAudio()
            let text = try await manager.finish()
            print("STREAMING repeat: \(text)")
            XCTAssertGreaterThan(recall(expected: phrase, actual: text), 0.6, text)
        }
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

/// Counts partial callbacks from whatever thread the model uses.
private final class PartialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { seen.append(text) }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }
}
