import AppKit
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
    ///
    /// This covers the case where the user starts speaking a moment before the key goes down.
    /// It only helps while the engine is already running, which is what the linger below is
    /// for: on a cold start the ring is deliberately cleared, because anything in it predates
    /// the engine stopping and splicing minute-old audio onto a new dictation would be worse
    /// than losing a syllable. A second of 16 kHz mono is 64 KB.
    nonisolated static let preRollDuration: TimeInterval = 1.0
    /// How long the engine keeps running after a dictation, ready for the next one.
    nonisolated static let lingerDuration: TimeInterval = 6
    /// Matches the controller's hold ceiling, and sets how much room a capture reserves.
    nonisolated static let maximumCaptureDuration: TimeInterval = 300

    private struct State {
        var isCapturing = false
        var captured: [Float] = []
        var ring = AudioRingBuffer(capacity: Int(AudioCapture.sampleRate * AudioCapture.preRollDuration))
        var converter: ConverterBox?
        /// Peak amplitude of the most recent buffer, for the level meter.
        var level: Float = 0
        /// Consecutive seconds below the silence threshold, for hands-free auto-stop.
        var silenceSeconds: TimeInterval = 0
        /// How much of `captured` the streaming transcriber has already been given.
        var drainedCount = 0
    }

    private var engine = AVAudioEngine()
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

    /// Starts listening for the events that invalidate a running engine.
    ///
    /// Neither of these had an observer, and both are routine. AirPods drop to 16 kHz whenever
    /// the microphone is activated, which changes the input format underneath a running engine;
    /// AVAudioEngine responds by stopping and uninitialising itself, and the installed tap goes
    /// silent. Because `engineRunning` still reads true, `startEngineIfNeeded` returned early and
    /// never reinstalled the tap, so the level meter sat at zero and every dictation came back
    /// empty until the six-second linger happened to tear things down. Sleep and wake leave the
    /// engine holding a stale hardware device id with the same result.
    func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverEngine(reason: "the audio configuration changed")
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverEngine(reason: "the machine woke")
            }
        }
    }

    /// Rebuilds the engine from scratch and resumes an in-flight capture.
    ///
    /// Restarting the existing engine is not enough: it keeps the hardware device id it resolved
    /// at creation, which is exactly what is stale after a device change or a wake.
    private func recoverEngine(reason: String) {
        let wasCapturing = state.withLock { $0.isCapturing }
        Log.audio.info("Rebuilding the audio engine because \(reason, privacy: .public); capturing=\(wasCapturing, privacy: .public)")

        try? Self.catchingObjC { self.engine.inputNode.removeTap(onBus: 0) }
        try? Self.catchingObjC { self.engine.stop() }
        engineRunning.withLock { $0 = false }
        engine = AVAudioEngine()

        guard wasCapturing else { return }
        // A capture is in progress, so the user is mid-sentence. Keep what was captured and
        // carry on at whatever format the new device offers.
        do {
            try startEngineIfNeeded()
            Log.audio.info("Capture resumed on the new device")
        } catch {
            Log.audio.error("Could not resume capture after \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Allocates engine resources without opening the microphone, so the first start is quick.
    func prepare() {
        // Touching `inputNode` is what attaches it to the graph. `prepare()` on an engine with
        // no nodes raises an Objective-C exception ("required condition is false: inputNode !=
        // nullptr || outputNode != nullptr"), which unwinds past Swift's `catch` and is
        // swallowed by the run loop: the app keeps running and the hotkey silently never starts.
        //
        // The trap means a future variant of that exception is reported rather than fatal.
        do {
            try Self.catchingObjC {
                _ = self.engine.inputNode
                self.engine.prepare()
            }
        } catch {
            Log.audio.error("Preparing the audio engine raised: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs AVFoundation work that may raise an Objective-C exception, as a Swift error.
    nonisolated static func catchingObjC(_ body: () -> Void) throws {
        var error: NSError?
        if !VFRunCatchingExceptions(body, &error) {
            throw error ?? Failure.engineFailed("unknown Objective-C exception")
        }
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
            // Reserve up front so appending on the audio thread is a memcpy rather than an
            // amortised reallocation that copies the whole capture. A five-minute ceiling of
            // 16 kHz mono floats is 19 MB, paid once per dictation instead of log(n) times
            // mid-sentence.
            state.captured.reserveCapacity(Int(Self.sampleRate * Self.maximumCaptureDuration))
            state.isCapturing = true
            state.silenceSeconds = 0
            state.drainedCount = 0
        }
        Log.audio.info("Capture started with \(self.preRollSampleCount, privacy: .public) samples of pre-roll")
    }

    private var preRollSampleCount: Int {
        state.withLock { $0.captured.count }
    }

    /// Samples captured since the last call, for transcribing while the user is still speaking.
    ///
    /// Pulling rather than pushing keeps the audio thread out of it entirely: the tap only ever
    /// appends to `captured` under the mutex, and the streaming transcriber collects from a
    /// normal task on its own schedule. Passing buffers across from the render callback would
    /// mean either allocating there or handing a non-Sendable buffer between threads.
    nonisolated func drainNewSamples() -> [Float] {
        state.withLock { state in
            guard state.captured.count > state.drainedCount else { return [] }
            let new = Array(state.captured[state.drainedCount...])
            state.drainedCount = state.captured.count
            return new
        }
    }

    /// How long to keep capturing after the key comes up.
    ///
    /// The tap delivers in 1024-frame buffers, so at key-up the last fraction of a second of
    /// speech has been spoken but not yet handed to us. Stopping immediately truncates the final
    /// word — the complaint every dictation app gets, and one Superwhisper shipped this same fix
    /// for. Two buffer periods at 48 kHz is comfortably enough.
    nonisolated static let postRollDuration: TimeInterval = 0.12

    /// Stops accumulating and returns the captured samples at 16 kHz mono, after waiting for
    /// the audio already spoken to arrive.
    func stopAfterPostRoll() async -> [Float] {
        try? await Task.sleep(for: .seconds(Self.postRollDuration))
        return stop()
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
        Log.audio.info("Capture stopped with \(samples.count, privacy: .public) samples (\(String(format: "%.2f", Double(samples.count) / Self.sampleRate), privacy: .public)s)")
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

        // installTap raises rather than throws when the format does not match the hardware,
        // which is routine when a device changes underneath us.
        do {
            try Self.catchingObjC {
                input.removeTap(onBus: 0)
                input.installTap(
                    onBus: 0,
                    bufferSize: 1024,
                    format: format,
                    block: self.makeTapBlock(target: target)
                )
                self.engine.prepare()
            }
        } catch {
            throw Failure.engineFailed(error.localizedDescription)
        }

        do {
            try engine.start()
        } catch {
            try? Self.catchingObjC { input.removeTap(onBus: 0) }
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

    /// Builds the microphone tap block.
    ///
    /// This must be `nonisolated`, and that is not a detail. `AVAudioNodeTapBlock` is not marked
    /// `@Sendable` in the SDK, so a closure written inline inside a `@MainActor` method silently
    /// inherits main-actor isolation. AVFoundation then calls it on the realtime audio thread,
    /// the runtime checks the executor and traps: `_dispatch_assert_queue_fail` with
    /// EXC_BREAKPOINT, killing the app the moment recording starts. Creating the closure in a
    /// nonisolated context is what stops it inheriting that isolation.
    nonisolated private func makeTapBlock(target: AVAudioFormat) -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            self?.consume(buffer, target: target)
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
