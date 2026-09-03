import XCTest
@testable import Visprflow

final class AudioRingBufferTests: XCTestCase {
    func testHoldsFewerSamplesThanCapacity() {
        var ring = AudioRingBuffer(capacity: 8)
        ring.append([1, 2, 3])
        XCTAssertEqual(ring.count, 3)
        XCTAssertFalse(ring.isFull)
        XCTAssertEqual(ring.snapshot(), [1, 2, 3])
    }

    func testKeepsMostRecentSamplesWhenFull() {
        var ring = AudioRingBuffer(capacity: 4)
        ring.append([1, 2, 3, 4, 5, 6])
        XCTAssertTrue(ring.isFull)
        XCTAssertEqual(ring.snapshot(), [3, 4, 5, 6], "the oldest samples fall off the back")
    }

    func testWrapsAcrossSeveralAppends() {
        var ring = AudioRingBuffer(capacity: 5)
        ring.append([1, 2, 3])
        ring.append([4, 5, 6])
        XCTAssertEqual(ring.snapshot(), [2, 3, 4, 5, 6])
        ring.append([7])
        XCTAssertEqual(ring.snapshot(), [3, 4, 5, 6, 7])
    }

    func testAppendLargerThanCapacityKeepsTail() {
        var ring = AudioRingBuffer(capacity: 3)
        ring.append([1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(ring.snapshot(), [7, 8, 9])
        XCTAssertEqual(ring.count, 3)
    }

    func testExactlyCapacityFillsWithoutWrapping() {
        var ring = AudioRingBuffer(capacity: 3)
        ring.append([1, 2, 3])
        XCTAssertEqual(ring.snapshot(), [1, 2, 3])
        XCTAssertTrue(ring.isFull)
    }

    func testEmptyAppendIsHarmless() {
        var ring = AudioRingBuffer(capacity: 4)
        ring.append([])
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.snapshot(), [])
    }

    func testRemoveAllResetsOrdering() {
        var ring = AudioRingBuffer(capacity: 3)
        ring.append([1, 2, 3, 4])
        ring.removeAll()
        XCTAssertEqual(ring.snapshot(), [])
        ring.append([9, 8])
        XCTAssertEqual(ring.snapshot(), [9, 8], "ordering is correct again after a reset")
    }

    func testHalfSecondOfAudioAtSampleRate() {
        // The real configuration: 500 ms of 16 kHz mono.
        var ring = AudioRingBuffer(capacity: Int(AudioCapture.sampleRate * AudioCapture.preRollDuration))
        XCTAssertEqual(ring.capacity, 8_000)
        ring.append([Float](repeating: 0.5, count: 10_000))
        XCTAssertEqual(ring.count, 8_000)
        XCTAssertEqual(ring.snapshot().count, 8_000)
    }
}
