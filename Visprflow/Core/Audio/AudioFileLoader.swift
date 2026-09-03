import AVFoundation
import Foundation

/// Reads an audio file into the 16 kHz mono Float32 samples the transcriber expects.
///
/// This is what lets the speech pipeline be tested without a microphone: audio synthesised
/// with `say` goes through the same resampling path as live capture.
enum AudioFileLoader {
    enum Failure: Error, LocalizedError {
        case unreadable(String)
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path): "Could not read the audio file at \(path)."
            case let .conversionFailed(message): "Could not convert the audio: \(message)"
            }
        }
    }

    static func samples(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url.path)
        }
        guard file.length > 0 else { return [] }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Failure.conversionFailed("could not build the 16 kHz mono format")
        }

        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw Failure.conversionFailed("no converter from \(sourceFormat.sampleRate) Hz")
        }

        // Read the whole file in one go, then convert once. Feeding the converter in chunks is
        // where this went wrong before: a partial read at the end makes it fail with a generic
        // error, and dictation-length audio is small enough that one buffer is the simpler
        // and more reliable path.
        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw Failure.conversionFailed("could not allocate the input buffer")
        }
        do {
            try file.read(into: input)
        } catch {
            throw Failure.conversionFailed(error.localizedDescription)
        }
        guard input.frameLength > 0 else { return [] }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure.conversionFailed("could not allocate the output buffer")
        }

        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }

        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw Failure.conversionFailed(conversionError?.localizedDescription ?? "unknown failure")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
