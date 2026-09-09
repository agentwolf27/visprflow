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

    func testHoldsTheConfiguredPreRollAtSampleRate() {
        // The real configuration: one second of 16 kHz mono, which is 64 KB. This only helps
        // while the engine is already running; a cold start clears the ring deliberately.
        let expected = Int(AudioCapture.sampleRate * AudioCapture.preRollDuration)
        var ring = AudioRingBuffer(capacity: expected)
        XCTAssertEqual(ring.capacity, 16_000)
        ring.append([Float](repeating: 0.5, count: expected + 2_000))
        XCTAssertEqual(ring.count, expected, "the ring holds exactly the pre-roll, no more")
        XCTAssertEqual(ring.snapshot().count, expected)
    }

    func testPreRollIsLongEnoughToCoverAnEarlyStart() {
        // Speaking a moment before the key goes down is the case this exists for, so the window
        // has to be a real fraction of a second rather than a token amount.
        XCTAssertGreaterThanOrEqual(AudioCapture.preRollDuration, 0.75)
        // And the post-roll has to outlast a tap buffer period, or the last word is truncated.
        XCTAssertGreaterThanOrEqual(AudioCapture.postRollDuration, 0.1)
    }
}
