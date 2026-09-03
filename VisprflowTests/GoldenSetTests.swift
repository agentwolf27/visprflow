import XCTest
@testable import Visprflow

final class GoldenSetTests: XCTestCase {
    private func goldenDirectory() throws -> URL {
        let bundle = Bundle(for: GoldenSetTests.self)
        let resources = try XCTUnwrap(bundle.resourceURL)
        return resources.appending(path: "Fixtures/golden", directoryHint: .isDirectory)
    }

    func testFixturesDecodeAndAreWellFormed() throws {
        let cases = try GoldenCase.loadAll(from: goldenDirectory())
        XCTAssertGreaterThanOrEqual(cases.count, 5, "the golden set seeds with the plan's examples")

        let ids = cases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")

        for item in cases {
            XCTAssertFalse(item.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            XCTAssertFalse(item.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            for term in item.mustContain {
                XCTAssertTrue(item.expected.contains(term), "\(item.id): expected output must contain \(term)")
            }
        }
    }

    func testExpectedOutputsPassMechanicalChecks() throws {
        for item in try GoldenCase.loadAll(from: goldenDirectory()) {
            XCTAssertFalse(OutputChecks.looksLikeAnswer(item.expected), "\(item.id) reads like an answer")
            XCTAssertFalse(OutputChecks.isTooLong(item.expected, comparedTo: item.transcript), "\(item.id) is over twice the transcript")
            XCTAssertFalse(item.expected.contains("```"), "\(item.id) contains a code fence")
        }
    }

    func testAnswerDetectorCatchesTheAssistantReflex() {
        XCTAssertTrue(OutputChecks.looksLikeAnswer("Sure! A mutex is..."))
        XCTAssertTrue(OutputChecks.looksLikeAnswer("Here's the cleaned up version:"))
        XCTAssertFalse(OutputChecks.looksLikeAnswer("What's the difference between a mutex and a semaphore?"))
    }

    func testVerbatimCasesAreUnchanged() throws {
        for item in try GoldenCase.loadAll(from: goldenDirectory()) where item.level == .verbatim {
            XCTAssertEqual(item.expected, item.transcript, "\(item.id): verbatim means unchanged")
        }
    }
}
