import CoreML
import FluidAudio
import Foundation

/// On-device speech recognition with NVIDIA Parakeet TDT 0.6B v3, running on the Neural Engine
/// through FluidAudio's Core ML port.
///
/// Chosen over Whisper for this app because it is roughly an order of magnitude faster at equal
/// or better English accuracy, which is what makes a sub-second key-up-to-text budget possible.
/// Audio never leaves the machine.
actor ParakeetTranscriber: Transcriber {
    nonisolated let id = "parakeet-tdt-0.6b-v3"
    nonisolated let displayName = "Parakeet v3 (on-device)"

    /// Below this the audio is almost certainly an accidental tap.
    private static let minimumSamples = Int(AudioCapture.sampleRate * 0.15)

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    /// Where the conformer encoder runs.
    ///
    /// Injectable so the memory cost of each placement can be measured rather than assumed —
    /// see `testEncoderPlacementFootprint`. The GPU is faster; it is not free.
    private let encoderComputeUnits: MLComputeUnits

    init(encoderComputeUnits: MLComputeUnits = ParakeetTranscriber.defaultEncoderComputeUnits) {
        self.encoderComputeUnits = encoderComputeUnits
    }

    /// The placement used by the app.
    ///
    /// This was `.cpuAndGPU` for a while, on the strength of FluidAudio's benchmark showing the
    /// conformer encoder about 8% faster there. Measured on this machine, that is wrong in both
    /// directions at once — `make verify-memory`, best of three on 4.9 s of speech:
    ///
    ///     encoder=gpu   1222 MB   306 ms
    ///     encoder=ane     13 MB   143 ms
    ///
    /// The Neural Engine is twice as fast and ninety times lighter, because GPU weights are
    /// Metal buffers in our own heap while ANE weights are not. A menu bar app that idles at
    /// 1.2 GB is the exact thing this project was started to replace.
    nonisolated static let defaultEncoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    func isReady() async -> Bool {
        manager != nil
    }

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await loadedManager(progress: progress)
    }

    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> Transcript {
        guard samples.count >= Self.minimumSamples else {
            throw TranscriberError.audioTooShort
        }
        let manager = try await loadedManager(progress: nil)

        let started = ContinuousClock.now
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples, decoderState: &state)
        } catch {
            throw TranscriberError.underlying(error.localizedDescription)
        }
        let elapsed = ContinuousClock.now - started

        let transcript = Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: result.confidence,
            audioDuration: Double(samples.count) / AudioCapture.sampleRate,
            processingTime: Trace.milliseconds(elapsed) / 1000
        )
        Log.stt.info("Transcribed \(String(format: "%.1f", transcript.audioDuration))s in \(String(format: "%.0f", transcript.processingTime * 1000))ms (\(String(format: "%.0f", transcript.realTimeFactor))x realtime)")
        return transcript
    }

    /// Releases the models. The next transcription reloads them.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        manager = nil
        Log.stt.info("Parakeet models unloaded")
    }

    // MARK: Private

    /// Loads once even if several dictations race to be first.
    /// Runs one throwaway inference so the first real dictation does not pay for it.
    ///
    /// Loading the models is not the whole cost: the first `transcribe` also compiles the Core ML
    /// graph and sets up Neural Engine scheduling. Without this the first dictation after launch
    /// is visibly slower than every one after it.
    private static func warmUp(_ manager: AsrManager) async {
        let silence = [Float](repeating: 0, count: Int(AudioCapture.sampleRate * 0.3))
        let started = ContinuousClock.now
        do {
            let layers = await manager.decoderLayerCount
            var state = TdtDecoderState.make(decoderLayers: layers)
            _ = try await manager.transcribe(silence, decoderState: &state)
            let elapsed = Trace.milliseconds(ContinuousClock.now - started)
            Log.stt.info("Warm-up inference took \(String(format: "%.0f", elapsed), privacy: .public)ms")
        } catch {
            // A failed warm-up costs nothing: the next real transcription simply pays the price
            // it would have paid anyway.
            Log.stt.info("Warm-up inference skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadedManager(progress: (@Sendable (Double) -> Void)?) async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let units = encoderComputeUnits
        let task = Task<AsrManager, Error> {
            Log.stt.info("Loading Parakeet v3 models (first run downloads roughly 600 MB)")
            let started = ContinuousClock.now
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                // See `defaultEncoderComputeUnits`: measured, not assumed.
                encoderComputeUnits: units,
                progressHandler: progress.map { handler -> ProgressHandler in
                    { update in handler(update.fractionCompleted) }
                }
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let elapsed = Trace.milliseconds(ContinuousClock.now - started) / 1000
            Log.stt.info("Parakeet ready in \(String(format: "%.1f", elapsed), privacy: .public)s")
            await Self.warmUp(manager)
            return manager
        }
        loadTask = task

        do {
            let manager = try await task.value
            self.manager = manager
            self.loadTask = nil
            return manager
        } catch {
            self.loadTask = nil
            Log.stt.error("Parakeet failed to load: \(error.localizedDescription, privacy: .public)")
            throw TranscriberError.underlying(error.localizedDescription)
        }
    }
}
