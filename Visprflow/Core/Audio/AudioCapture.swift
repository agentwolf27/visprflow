import AVFoundation
import Foundation
import Synchronization

/// Microphone capture, resampled to the 16 kHz mono Float32 that every speech model here wants.
///
/// The engine starts on key-down and lingers for a few seconds after a dictation ends, so a
/// second dictation begins with the input already running. A ring buffer holds the most recent
/// audio while the engine is idling, which becomes the pre-roll of the next capture: the opening
/// word survives even if the user starts speaking a moment before the key goes down.
///
/// Engine control is confined to the main actor. Only `consume` runs on the audio thread, and it
/// touches nothing but the mutex-protected state, so audio-thread work never blocks on an actor.
@MainActor
final class AudioCapture {
    enum Failure: Error, LocalizedError {
        case noInputDevice
        case converterUnavailable
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .converterUnavailable: "Could not convert microphone audio to 16 kHz mono."
            case let .engineFailed(message): "The audio engine failed to start: \(message)"
            }
        }
    }

    /// `AVAudioConverter` is not Sendable, but it is only ever touched inside the mutex, on one
    /// thread at a time. The box makes that promise explicit to the compiler.
    private final class ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        init(_ converter: AVAudioConverter) { self.converter = converter }
    }

    nonisolated static let sampleRate: Double = 16_000
    /// How much audio the ring keeps for pre-roll.
    nonisolated static let preRollDuration: TimeInterval = 0.5
    /// How long the engine keeps running after a dictation, ready for the next one.
    nonisolated static let lingerDuration: TimeInterval = 6

    private struct State {
        var isCapturing = false
        var captured: [Float] = []
        var ring = AudioRingBuffer(capacity: Int(AudioCapture.sampleRate * AudioCapture.preRollDuration))
        var converter: ConverterBox?
        /// Peak amplitude of the most recent buffer, for the level meter.
        var level: Float = 0
        /// Consecutive seconds below the silence threshold, for hands-free auto-stop.
        var silenceSeconds: TimeInterval = 0
    }

    private let engine = AVAudioEngine()
    private let state = Mutex(State())
    private let engineRunning = Mutex(false)
    private let lingerTask = Mutex<Task<Void, Never>?>(nil)

    /// Amplitude below which audio counts as silence for hands-free auto-stop.
    nonisolated static let silenceThreshold: Float = 0.012

    nonisolated var currentLevel: Float {
        state.withLock { $0.level }
    }

    nonisolated var silenceSeconds: TimeInterval {
        state.withLock { $0.silenceSeconds }
    }

    /// Allocates engine resources without opening the microphone, so the first start is quick.
    func prepare() {
        // Touching `inputNode` is what attaches it to the graph. `prepare()` on an engine with
        // no nodes raises an Objective-C exception ("required condition is false: inputNode !=
        // nullptr || outputNode != nullptr"), which unwinds past Swift's `catch` and is
        // swallowed by the run loop: the app keeps running and the hotkey silently never starts.
        _ = engine.inputNode
        engine.prepare()
    }

    /// Starts (or reuses) the engine and begins accumulating samples.
    /// Any audio already in the ring becomes the pre-roll of this capture.
    func start() throws {
        lingerTask.withLock { task in
            task?.cancel()
            task = nil
        }

        try startEngineIfNeeded()

        state.withLock { state in
            state.captured = state.ring.snapshot()
            state.isCapturing = true
            state.silenceSeconds = 0
        }
        Log.audio.info("Capture started with \(self.preRollSampleCount) samples of pre-roll")
    }

    private var preRollSampleCount: Int {
        state.withLock { $0.captured.count }
    }

    /// Stops accumulating and returns the captured samples at 16 kHz mono.
    /// The engine keeps running briefly in case another dictation follows.
    @discardableResult
    func stop() -> [Float] {
        let samples = state.withLock { state -> [Float] in
            state.isCapturing = false
            let captured = state.captured
            state.captured = []
            return captured
        }
        scheduleLingerStop()
        Log.audio.info("Capture stopped with \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Self.sampleRate))s)")
        return samples
    }

    /// Stops and throws the audio away.
    func discard() {
        state.withLock { state in
            state.isCapturing = false
            state.captured = []
        }
        scheduleLingerStop()
    }

    /// Stops the engine immediately, releasing the microphone.
    func shutdown() {
        lingerTask.withLock { task in
            task?.cancel()
            task = nil
        }
        stopEngine()
    }

    // MARK: Engine

    private func startEngineIfNeeded() throws {
        let alreadyRunning = engineRunning.withLock { $0 }
        if alreadyRunning, engine.isRunning { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure.noInputDevice
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            throw Failure.converterUnavailable
        }

        state.withLock { state in
            state.converter = ConverterBox(converter)
            state.ring.removeAll()
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, target: target)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed(error.localizedDescription)
        }

        engineRunning.withLock { $0 = true }
        Log.audio.info("Audio engine started at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    private func stopEngine() {
        let wasRunning = engineRunning.withLock { running -> Bool in
            defer { running = false }
            return running
        }
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.withLock { state in
            state.ring.removeAll()
            state.level = 0
        }
        Log.audio.info("Audio engine stopped")
    }

    private func scheduleLingerStop() {
        lingerTask.withLock { task in
            task?.cancel()
            task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.lingerDuration))
                guard !Task.isCancelled else { return }
                await self?.stopEngine()
            }
        }
    }

    /// Runs on the audio thread. Converts to 16 kHz mono and feeds the ring and the capture.
    nonisolated private func consume(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        let status = state.withLock { state -> AVAudioConverterOutputStatus? in
            guard let box = state.converter else { return nil }
            return box.converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
        }

        guard status == .haveData || status == .inputRanDry, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            if let error { Log.audio.error("Conversion failed: \(error.localizedDescription, privacy: .public)") }
            return
        }

        let frames = Int(output.frameLength)
        let samples = UnsafeBufferPointer(start: channel, count: frames)

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        let seconds = Double(frames) / target.sampleRate

        state.withLock { state in
            state.level = peak
            state.ring.append(samples)
            if state.isCapturing {
                state.captured.append(contentsOf: samples)
                state.silenceSeconds = peak < Self.silenceThreshold ? state.silenceSeconds + seconds : 0
            }
        }
    }
}
