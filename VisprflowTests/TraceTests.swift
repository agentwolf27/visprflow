import XCTest
@testable import Visprflow

final class TraceTests: XCTestCase {
    func testMarksAreOrderedAndMeasurable() throws {
        var trace = Trace()
        trace.mark(.keyDown)
        trace.mark(.keyUp)
        usleep(5_000) // 5 ms
        trace.mark(.transcriptReady)
        trace.mark(.inserted)

        XCTAssertEqual(trace.marks.map(\.stage), [.keyDown, .keyUp, .transcriptReady, .inserted])

        let keyUpToTranscript = try XCTUnwrap(trace.duration(from: .keyUp, to: .transcriptReady))
        XCTAssertGreaterThanOrEqual(Trace.milliseconds(keyUpToTranscript), 4)

        let keyUpToInserted = try XCTUnwrap(trace.duration(from: .keyUp, to: .inserted))
        XCTAssertGreaterThanOrEqual(keyUpToInserted, keyUpToTranscript)
    }

    func testRemarkingReplacesEarlierMark() throws {
        var trace = Trace()
        trace.mark(.keyUp)
        let first = try XCTUnwrap(trace.offset(of: .keyUp))
        usleep(2_000)
        trace.mark(.keyUp)
        let second = try XCTUnwrap(trace.offset(of: .keyUp))
        XCTAssertEqual(trace.marks.count, 1)
        XCTAssertGreaterThan(second, first, "the mark must move forward, not keep the old offset")
    }

    func testMissingStageYieldsNil() {
        var trace = Trace()
        trace.mark(.keyUp)
        XCTAssertNil(trace.duration(from: .keyUp, to: .inserted))
    }

    func testStageDurationsSumToLastOffset() throws {
        var trace = Trace()
        trace.mark(.keyDown)
        trace.mark(.keyUp)
        trace.mark(.inserted)
        let durations = trace.stageDurations()
        let total = durations.reduce(Duration.zero) { $0 + $1.sinceLast }
        XCTAssertEqual(total, try XCTUnwrap(trace.offset(of: .inserted)))
    }

    func testSummaryNamesEveryStage() {
        var trace = Trace()
        trace.mark(.keyUp)
        trace.mark(.inserted)
        let summary = trace.summary()
        XCTAssertTrue(summary.contains("keyUp+"))
        XCTAssertTrue(summary.contains("inserted+"))
        XCTAssertTrue(summary.hasSuffix("ms"))
    }
}
