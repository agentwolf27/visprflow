import AVFoundation
import CoreML
import XCTest
@testable import Visprflow

/// What the speech models cost in memory, measured rather than assumed.
///
/// This exists because a claim of "6 MB idle" went into a build report on the strength of
/// `ps rss`, which counts neither Core ML's weight buffers nor the Neural Engine's allocation,
/// and was read before any model had loaded. The real figure was two hundred times larger.
///
/// It lives in its own class so it runs in a process where nothing has loaded a model yet.
/// Sharing a process with the other speech tests would measure a model that is already resident
/// and report almost nothing, which is exactly the mistake this file is here to prevent.
///
/// Run with `make verify-memory`, or `VISPRFLOW_ENCODER=ane make verify-memory` for the other
/// encoder placement.
final class MemoryIntegrationTests: XCTestCase {
    private static let isEnabled = ProcessInfo.processInfo.environment["VISPRFLOW_STT"] == "1"

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.isEnabled, "set VISPRFLOW_STT=1 to run the memory tests")
    }

    /// The conformer encoder can run on the GPU or the Neural Engine. The GPU is about 8% faster
    /// end to end, which is why the app chose it — but GPU weights are Metal buffers in our own
    /// heap, while Neural Engine weights are charged to the ANE. This prints what each placement
    /// actually costs so the trade is made on numbers.
    func testEncoderPlacementFootprint() async throws {
        // Unset means "measure what we actually ship", so this is a regression guard by default
        // and a comparison only when asked.
        let requested = ProcessInfo.processInfo.environment["VISPRFLOW_ENCODER"] ?? "default"
        let units: MLComputeUnits
        switch requested {
        case "gpu": units = .cpuAndGPU
        case "ane": units = .cpuAndNeuralEngine
        default: units = ParakeetTranscriber.defaultEncoderComputeUnits
        }

        let baseline = Self.footprintBytes()
        let transcriber = ParakeetTranscriber(encoderComputeUnits: units)
        // `prepare` loads the models and runs one throwaway inference, so everything allocated
        // lazily on the first pass is allocated by the time this returns.
        try await transcriber.prepare()
        let loaded = Self.footprintBytes()

        let cost = Double(loaded &- baseline) / 1_048_576

        // Both halves of the trade, from the same run: the memory a placement costs and the
        // speed it buys. Quoting the vendor's "8% faster" without the megabytes beside it is how
        // this got chosen in the first place.
        let audio = try synthesisedSamples("the login flow is broken after the token expires so write a failing test first")
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let transcript = try await transcriber.transcribe(samples: audio, hints: .none)
            best = min(best, Trace.milliseconds(ContinuousClock.now - started))
            XCTAssertFalse(transcript.text.isEmpty, "the model produced no text; the timing means nothing")
        }

        print(String(
            format: "MEMORY encoder=%@ cost %.0f MB, best of 3 transcriptions %.0f ms for %.1fs of audio",
            requested,
            cost,
            best,
            Double(audio.count) / AudioCapture.sampleRate
        ))

        XCTAssertGreaterThan(cost, 5, "nothing was allocated at all; the measurement means nothing")
        // A ceiling, not a target. The plan budgeted 50–150 MB idle for the whole app. The
        // Neural Engine placement lands near 22 MB in-process; the GPU one cost 1204 MB, which
        // is the regression this line exists to catch.
        XCTAssertLessThan(cost, 300, "the batch model is holding far more of our own heap than it should")
    }

    /// A spoken sentence at 16 kHz mono, through the same resampling path as live capture.
    private func synthesisedSamples(_ text: String) throws -> [Float] {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["-o", scratch.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("`say` produced no audio") }

        let file = try AVAudioFile(forReading: scratch)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw XCTSkip("no converter for the synthesised format")
        }
        let capacity = AVAudioFrameCount(
            Double(file.length) * target.sampleRate / file.processingFormat.sampleRate
        ) + 4096
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )!
            try? file.read(into: input)
            status.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        let channel = output.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// This process's physical footprint — the same figure `footprint(1)` reports, and the only
    /// one that counts Core ML's allocations. `ps rss` does not.
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
