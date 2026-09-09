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

    /// The audit noted that the golden set checked its own fixtures but never ran them
    /// through the guardrails, so the invention check had no golden coverage at all.
    func testEveryExpectedOutputPassesTheRealGuardrails() throws {
        let guardrails = Guardrails.default
        for item in try GoldenCase.loadAll(from: goldenDirectory()) {
            let verdict = guardrails.check(output: item.expected, transcript: item.transcript)
            XCTAssertTrue(verdict.passed, "\(item.id) would be rejected: \(verdict.reason ?? "")")
        }
    }

    /// The mirror image: output that shows a known failure mode must be caught for every
    /// fixture, so the guardrails are not silently passing everything.
    func testGuardrailsRejectAnsweringForEveryFixture() throws {
        let guardrails = Guardrails.default
        for item in try GoldenCase.loadAll(from: goldenDirectory()) where item.level != .verbatim {
            let verdict = guardrails.check(
                output: "Sure! Here is what I think about that.",
                transcript: item.transcript
            )
            XCTAssertFalse(verdict.passed, "\(item.id) should have rejected an answer")
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
