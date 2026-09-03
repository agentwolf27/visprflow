import XCTest
@testable import Visprflow

/// Covers the pieces the phase 0 audit found untested: the mechanical output checks, the
/// Keychain round trip, timing-row construction, permission reporting, and fixture decoding.
final class OutputChecksTests: XCTestCase {
    func testWordCountIgnoresRunsOfWhitespace() {
        XCTAssertEqual(OutputChecks.wordCount("one   two\n\nthree\tfour"), 4)
        XCTAssertEqual(OutputChecks.wordCount("   "), 0)
        XCTAssertEqual(OutputChecks.wordCount(""), 0)
    }

    func testIsTooLongFiresWhenTheModelPadsTheOutput() {
        let transcript = "fix the login bug"          // 4 words
        XCTAssertFalse(OutputChecks.isTooLong("Fix the login bug.", comparedTo: transcript))
        // 9 words is more than twice 4, which is the sign the model started writing prose.
        XCTAssertTrue(OutputChecks.isTooLong(
            "Sure, I will go ahead and fix the login bug for you right away please",
            comparedTo: transcript
        ))
    }

    func testIsTooLongUsesTheRatioItIsGiven() {
        let transcript = "a b c d"
        let output = "a b c d e f"  // 1.5x
        XCTAssertFalse(OutputChecks.isTooLong(output, comparedTo: transcript, ratio: 2.0))
        XCTAssertTrue(OutputChecks.isTooLong(output, comparedTo: transcript, ratio: 1.2))
    }

    func testEmptyTranscriptDoesNotDivideByZero() {
        XCTAssertTrue(OutputChecks.isTooLong("some output here", comparedTo: ""))
    }

    func testAnswerDetectionIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(OutputChecks.looksLikeAnswer("  Of course! Here you go"))
        XCTAssertTrue(OutputChecks.looksLikeAnswer("CERTAINLY, the answer is 42"))
        XCTAssertTrue(OutputChecks.looksLikeAnswer("I cannot help with that"))
    }

    func testMetaCommentaryAboutTheOutputIsFlagged() {
        XCTAssertTrue(OutputChecks.looksLikeAnswer("Here's the rewritten prompt: fix the bug"))
        XCTAssertTrue(OutputChecks.looksLikeAnswer("Here is the cleaned transcript below"))
        XCTAssertTrue(OutputChecks.looksLikeAnswer("As an AI, I should note that"))
    }

    func testInterjectionNeedsPunctuationToCount() {
        // The reflex: an interjection closed off by punctuation.
        XCTAssertTrue(OutputChecks.looksLikeAnswer("Okay, I'll fix that for you"))
        XCTAssertTrue(OutputChecks.looksLikeAnswer("Sure!"))
        // The same words continuing into a real sentence are legitimate dictation.
        XCTAssertFalse(OutputChecks.looksLikeAnswer("Okay so the retry logic needs a backoff"))
    }

    func testLegitimateRewritesAreNotFlagged() {
        // These begin with words that must never be mistaken for the assistant reflex.
        for text in [
            "Here's the thing, the parser drops trailing commas",   // the user actually said this
            "Sure looks like a race condition in the worker pool",
            "Certainly worth checking whether the index exists",
        ] {
            XCTAssertFalse(OutputChecks.looksLikeAnswer(text), "false positive on: \(text)")
        }
    }
}

final class KeychainTests: XCTestCase {
    // A key that cannot collide with the real ones the app stores.
    private let key = SecretKey.groqAPIKey

    override func tearDown() {
        try? Keychain.delete(key)
        super.tearDown()
    }

    func testRoundTrip() throws {
        try Keychain.set("secret-value-1", for: key)
        XCTAssertEqual(try Keychain.get(key), "secret-value-1")
    }

    func testOverwritingReplacesTheValue() throws {
        try Keychain.set("first", for: key)
        try Keychain.set("second", for: key)
        XCTAssertEqual(try Keychain.get(key), "second")
    }

    func testMissingKeyReadsAsNilRatherThanThrowing() throws {
        try Keychain.delete(key)
        XCTAssertNil(try Keychain.get(key))
    }

    func testDeletingTwiceIsNotAnError() throws {
        try Keychain.set("x", for: key)
        try Keychain.delete(key)
        XCTAssertNoThrow(try Keychain.delete(key), "deleting an absent item is a no-op")
    }

    func testUnicodeAndLongValuesSurvive() throws {
        let value = String(repeating: "sk-ant-π→✓", count: 40)
        try Keychain.set(value, for: key)
        XCTAssertEqual(try Keychain.get(key), value)
    }
}

final class TimingRowTests: XCTestCase {
    func testRowsCarryOffsetsAndDeltasInMilliseconds() {
        var trace = Trace()
        trace.mark(.keyDown, offset: .zero)
        trace.mark(.keyUp, offset: .milliseconds(1_200))
        trace.mark(.transcriptReady, offset: .milliseconds(1_280))
        trace.mark(.inserted, offset: .milliseconds(1_410))

        let rows = StageTimingRecord.rows(for: trace, dictationId: "d1")
        XCTAssertEqual(rows.map(\.stage), ["keyDown", "keyUp", "transcriptReady", "inserted"])
        XCTAssertEqual(rows[2].offsetMs, 1_280, accuracy: 0.001)
        XCTAssertEqual(rows[2].sinceLastMs, 80, accuracy: 0.001, "80 ms of transcription")
        XCTAssertEqual(rows[3].sinceLastMs, 130, accuracy: 0.001, "130 ms to insert")
        XCTAssertTrue(rows.allSatisfy { $0.dictationId == "d1" })
    }

    func testKeyUpToInsertedIsTheBudgetThePlanTracks() throws {
        var trace = Trace()
        trace.mark(.keyDown, offset: .zero)
        trace.mark(.keyUp, offset: .milliseconds(1_200))
        trace.mark(.inserted, offset: .milliseconds(1_450))
        let budget = try XCTUnwrap(trace.duration(from: .keyUp, to: .inserted))
        XCTAssertEqual(Trace.milliseconds(budget), 250, accuracy: 0.001)
    }

    func testSummaryIsLocaleIndependent() {
        var trace = Trace()
        trace.mark(.keyUp, offset: .milliseconds(1_234))
        // A locale-aware formatter would render this as "1.234" in de_DE and break log greps.
        XCTAssertEqual(trace.summary(), "keyUp+1234ms")
    }

    func testRemarkingAStageMovesItsOffsetForward() throws {
        var trace = Trace()
        trace.mark(.keyUp, offset: .milliseconds(10))
        trace.mark(.keyUp, offset: .milliseconds(90))
        XCTAssertEqual(trace.marks.count, 1)
        XCTAssertEqual(Trace.milliseconds(try XCTUnwrap(trace.offset(of: .keyUp))), 90, accuracy: 0.001)
    }
}

final class PermissionStatusTests: XCTestCase {
    func testAllGrantedRequiresEveryPermission() {
        XCTAssertFalse(PermissionStatus(microphone: true, accessibility: true, inputMonitoring: false).allGranted)
        XCTAssertTrue(PermissionStatus(microphone: true, accessibility: true, inputMonitoring: true).allGranted)
    }

    func testIsGrantedMapsEachCase() {
        let status = PermissionStatus(microphone: true, accessibility: false, inputMonitoring: true)
        XCTAssertTrue(status.isGranted(.microphone))
        XCTAssertFalse(status.isGranted(.accessibility))
        XCTAssertTrue(status.isGranted(.inputMonitoring))
    }

    func testDescriptionNamesEveryPermission() {
        let text = PermissionStatus().description
        for permission in Permission.allCases {
            XCTAssertTrue(text.contains(permission.rawValue), "missing \(permission.rawValue)")
        }
    }

    func testEveryPermissionHasASettingsDeepLink() {
        for permission in Permission.allCases {
            XCTAssertEqual(permission.settingsURL.scheme, "x-apple.systempreferences")
            XCTAssertFalse(permission.why.isEmpty)
        }
    }
}

final class GoldenCaseDecodingTests: XCTestCase {
    func testDestinationAndLevelDecodeFromTheirWireNames() throws {
        let json = """
        {"id":"x","destination":"claude_code","level":"FULL","transcript":"a","expected":"b"}
        """
        let item = try JSONDecoder().decode(GoldenCase.self, from: Data(json.utf8))
        XCTAssertEqual(item.destination, .claudeCode)
        XCTAssertEqual(item.level, .full)
    }

    func testMustContainDefaultsToEmptyWhenAbsent() throws {
        // Swift's synthesised Decodable would throw here; the custom initialiser must not.
        let json = """
        {"id":"x","destination":"message","level":"LIGHT","transcript":"a","expected":"b"}
        """
        let item = try JSONDecoder().decode(GoldenCase.self, from: Data(json.utf8))
        XCTAssertEqual(item.mustContain, [])
        XCTAssertNil(item.notes)
    }

    func testMissingRequiredFieldStillThrows() {
        let json = #"{"id":"x","destination":"message","level":"LIGHT"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(GoldenCase.self, from: Data(json.utf8)))
    }
}
