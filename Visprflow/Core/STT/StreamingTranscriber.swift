import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Transcribes while the user is still speaking, so the text is ready when they let go.
///
/// The batch transcriber only starts work once the key comes up, which leaves the whole time
/// someone is talking idle. This runs a cache-aware streaming model alongside the capture: audio
/// goes in as it arrives, partial text comes back, and `finish()` returns the final transcript
/// with the tail already decoded.
///
/// The partials are for our own overlay only. Streaming provisional text into the app the user is
/// typing into would mean retracting it when the model revises itself, and text already inserted
/// cannot be reliably taken back in terminals, Electron apps or web views — exactly where this
/// tool is used.
actor StreamingTranscriber {
    /// 320 ms chunks: the shortest cache-aware variant that uses the same 0.6B Parakeet family
    /// as the batch path, so accuracy is comparable and no second large model is downloaded.
    static let variant: StreamingModelVariant = .parakeetUnified320ms

    /// How often buffered audio is handed to the model. Below the chunk size there is nothing
    /// new to decode; far above it and the partials lag the speaker.
    static let drainInterval: Duration = .milliseconds(250)

    private var manager: (any StreamingAsrManager)?
    private var loadTask: Task<any StreamingAsrManager, Error>?
    private var session: Task<Void, Never>?

    /// The format the samples arrive in, matching `AudioCapture`'s converter output.
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCapture.sampleRate,
        channels: 1,
        interleaved: false
    )

    var isLoaded: Bool { manager != nil }

    /// Downloads and loads the streaming model. Safe to call repeatedly.
    @discardableResult
    func prepare() async throws -> any StreamingAsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let task = Task<any StreamingAsrManager, Error> {
            let started = ContinuousClock.now
            let manager = Self.variant.createManager()
            try await manager.loadModels()
            let elapsed = Trace.milliseconds(ContinuousClock.now - started) / 1000
            Log.stt.info("Streaming model ready in \(String(format: "%.1f", elapsed), privacy: .public)s")
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
            throw error
        }
    }

    /// Starts consuming audio from `capture` until `finish()` is called.
    ///
    /// `onPartial` fires on the main actor with the transcript so far.
    func begin(
        draining capture: AudioCapture,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        let manager = try await prepare()
        try await manager.reset()
        await manager.setPartialTranscriptCallback(onPartial)

        session?.cancel()
        session = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                guard !Task.isCancelled else { break }
                await self?.feed(from: capture, into: manager)
            }
        }
    }

    /// Hands whatever has been captured since the last pass to the model.
    private func feed(from capture: AudioCapture, into manager: any StreamingAsrManager) async {
        do {
            guard try await append(capture.drainNewSamples(), to: manager) else { return }
            try await manager.processBufferedAudio()
        } catch {
            // A failed chunk is not fatal: the batch transcriber still runs on the full audio
            // at key-up, so the worst case is losing the live preview for this dictation.
            Log.stt.error("Streaming chunk failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies samples into a fresh buffer and hands it to the model. Returns false when there
    /// was nothing to send.
    ///
    /// The buffer is built here rather than by a helper so that it is created and transferred in
    /// one scope: `AVAudioPCMBuffer` is not Sendable, and passing it to the model's actor is only
    /// safe because nothing on this side keeps a reference.
    @discardableResult
    private func append(_ samples: [Float], to manager: any StreamingAsrManager) async throws -> Bool {
        guard !samples.isEmpty, let format else { return false }
        // AVAudioPCMBuffer is not Sendable, and FluidAudio's streaming API takes one across an
        // actor boundary by design — their own code does the same, built without complete
        // concurrency checking. `nonisolated(unsafe)` scopes the exemption to this single
        // handover rather than declaring the whole type Sendable process-wide, which would
        // silence the checker everywhere including the audio thread. The promise being made
        // here is narrow and true: the buffer is allocated in the line below, filled once, and
        // never referenced again on this side.
        nonisolated(unsafe) let buffer = Self.makeBuffer(samples, format: format)
        try await manager.appendAudio(buffer)
        return true
    }

    /// Copies samples into a fresh buffer. Callers pass the result directly to `appendAudio`.
    private nonisolated static func makeBuffer(
        _ samples: [Float],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Stops consuming audio and clears the session.
    ///
    /// No transcript is taken from here. The streaming model exists to show words while the user
    /// is speaking; the text that gets used comes from the more accurate batch model, which is
    /// fast enough that there is nothing to gain by preferring the streamed version.
    func stop() async {
        session?.cancel()
        session = nil
        try? await manager?.reset()
    }

    /// Abandons the session without producing a transcript.
    func cancel() async {
        session?.cancel()
        session = nil
        try? await manager?.reset()
    }

}
