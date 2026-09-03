import Foundation

/// Fixed-capacity ring of audio samples.
///
/// The capture engine writes into this from the audio thread; when a gesture starts we
/// take everything it holds as pre-roll, so the opening word survives even though the
/// user starts speaking slightly before, or slightly after, the key goes down. Wispr Flow
/// documents discarding a little audio at the start of every recording, which is exactly
/// the failure this avoids.
struct AudioRingBuffer: Sendable {
    private var storage: [Float]
    private var writeIndex = 0
    private(set) var count = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "ring buffer needs room for at least one sample")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    var isFull: Bool { count == capacity }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        // Only the last `capacity` samples can survive, so skip anything older.
        let incoming = samples.count
        let skip = max(0, incoming - capacity)
        var index = skip
        while index < incoming {
            let chunk = min(capacity - writeIndex, incoming - index)
            storage.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.advanced(by: writeIndex)
                    .update(from: base.advanced(by: index), count: chunk)
            }
            writeIndex = (writeIndex + chunk) % capacity
            index += chunk
        }
        count = min(capacity, count + (incoming - skip))
    }

    /// Samples in chronological order, oldest first.
    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(storage[0..<count])
        }
        // Full: the oldest sample sits at the write cursor.
        return Array(storage[writeIndex..<capacity]) + Array(storage[0..<writeIndex])
    }

    mutating func removeAll() {
        writeIndex = 0
        count = 0
    }
}
