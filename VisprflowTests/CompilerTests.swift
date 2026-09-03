import XCTest
@testable import Visprflow

final class GuardrailsTests: XCTestCase {
    private let guardrails = Guardrails.default

    func testCleanRewritePasses() {
        let verdict = guardrails.check(
            output: "Users are getting logged out after their token expires. Fix the token refresh under src/auth/.",
            transcript: "the login thing is broken users get logged out after the token expires it's in src slash auth the token refresh"
        )
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    func testAnsweringInsteadOfRewritingIsRejected() {
        let verdict = guardrails.check(
            output: "Sure! A mutex provides mutual exclusion while a semaphore counts permits.",
            transcript: "what's the difference between a mutex and a semaphore"
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "the model answered instead of rewriting")
    }

    func testPaddedOutputIsRejected() {
        let verdict = guardrails.check(
            output: "I will go ahead and carefully fix the login bug for you as soon as possible today",
            transcript: "fix the login bug"
        )
        XCTAssertFalse(verdict.passed)
    }

    func testAddedCodeBlockIsRejected() {
        let verdict = guardrails.check(
            output: "Here you go\n```swift\nlet x = 1\n```",
            transcript: "add a variable called x"
        )
        XCTAssertFalse(verdict.passed)
    }

    func testCodeBlockIsAllowedWhenTheSpeakerDictatedOne() {
        let transcript = "paste this ```let x = 1``` into the file"
        let verdict = guardrails.check(output: "Paste this ```let x = 1``` into the file.", transcript: transcript)
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    // MARK: Invention

    func testSpokenPathIsNotTreatedAsInvented() {
        // "src slash auth" legitimately becomes src/auth. A literal check would reject this.
        let verdict = guardrails.check(
            output: "Fix the token refresh in src/auth/session.swift",
            transcript: "fix the token refresh in src slash auth slash session dot swift"
        )
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    func testSpokenCamelCaseIsNotTreatedAsInvented() {
        let verdict = guardrails.check(
            output: "Rename the helper to parseDate and update its imports.",
            transcript: "rename the helper to parse date camel case and update the imports"
        )
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    func testHallucinatedFileNameIsRejected() {
        let verdict = guardrails.check(
            output: "Fix the login bug in src/controllers/AuthenticationController.swift",
            transcript: "fix the login bug"
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertTrue(verdict.reason?.contains("never said") == true, verdict.reason ?? "")
    }

    func testVocabularyAuthorisesTermsTheSpeakerUsed() {
        // The speaker said "visprflow"; the project spells it that way, so it is not invented.
        let verdict = guardrails.check(
            output: "Update VisprflowApp.swift with the new hotkey",
            transcript: "update visprflow app swift with the new hotkey",
            vocabulary: ["VisprflowApp.swift"]
        )
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    func testOrdinaryProseWithPunctuationIsNotFlagged() {
        let verdict = guardrails.check(
            output: "Let's ship it. The tests pass, and the build is green.",
            transcript: "let's ship it the tests pass and the build is green"
        )
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    func testUrlsInTheTranscriptSurvive() {
        let verdict = guardrails.check(
            output: "Check https://example.com/status for the outage.",
            transcript: "check https example dot com slash status for the outage"
        )
        XCTAssertTrue(verdict.passed, verdict.reason ?? "")
    }

    func testEmptyOutputIsRejectedForRealSpeech() {
        let verdict = guardrails.check(output: "", transcript: "fix the login bug please")
        XCTAssertFalse(verdict.passed)
    }

    func testEmptyOutputIsFineForFillerOnlyInput() {
        XCTAssertTrue(guardrails.check(output: "", transcript: "um uh").passed)
    }

    // MARK: Token extraction

    func testIdentifierDetectionCoversPathsCaseAndUnderscores() {
        let tokens = Guardrails.identifierLikeTokens(in: "Update src/auth.swift and parseDate and MAX_RETRIES today")
        XCTAssertTrue(tokens.contains("src/auth.swift"))
        XCTAssertTrue(tokens.contains("parseDate"))
        XCTAssertTrue(tokens.contains("MAX_RETRIES"))
        XCTAssertFalse(tokens.contains("Update"))
        XCTAssertFalse(tokens.contains("today"))
    }

    func testSentenceEndingFullStopIsNotAnIdentifier() {
        let tokens = Guardrails.identifierLikeTokens(in: "Ship it. Then rest.")
        XCTAssertTrue(tokens.isEmpty, "got \(tokens)")
    }

    func testWordPartsSplitOnCamelCaseAndSeparators() {
        let guardrails = Guardrails.default
        XCTAssertEqual(guardrails.wordParts("src/auth/session.swift"), ["src", "auth", "session", "swift"])
        XCTAssertEqual(guardrails.wordParts("parseDateFromISO"), ["parse", "date", "from", "iso"])
        XCTAssertEqual(guardrails.wordParts("MAX_RETRIES"), ["max", "retries"])
    }
}

final class CompilerTests: XCTestCase {
    private func compiler(returning output: String) -> Compiler {
        var mock = MockGenerator()
        mock.fallback = { _ in output }
        return Compiler(generator: mock)
    }

    func testVerbatimNeverCallsTheModel() async throws {
        var mock = MockGenerator()
        mock.failure = .transport("the model must not be called for verbatim")
        let compiler = Compiler(generator: mock)

        let result = try await compiler.compile(
            CompileRequest(transcript: "git push --force-with-lease", level: .verbatim, destination: "shell")
        )
        XCTAssertEqual(result.text, "git push --force-with-lease")
        XCTAssertEqual(result.level, .verbatim)
        XCTAssertFalse(result.usedRawFallback)
    }

    func testGoodOutputIsReturnedAtTheRequestedLevel() async throws {
        let result = try await compiler(returning: "Fix the login bug.")
            .compile(CompileRequest(transcript: "um fix the login bug", level: .light))
        XCTAssertEqual(result.text, "Fix the login bug.")
        XCTAssertEqual(result.level, .light)
        XCTAssertNil(result.guardrailReason)
    }

    func testStreamedDeltasReachTheCaller() async throws {
        let collected = Collector()
        _ = try await compiler(returning: "Fix the login bug.")
            .compile(CompileRequest(transcript: "um fix the login bug", level: .light)) { delta in
                collected.append(delta)
            }
        XCTAssertEqual(collected.joined().trimmingCharacters(in: .whitespaces), "Fix the login bug.")
    }

    func testRejectedOutputRetriesOneLevelLower() async throws {
        // Full is rejected for inventing a file; light returns something clean.
        var mock = MockGenerator()
        mock.responses = [
            { request in
                request.user.contains("<edit_level>FULL</edit_level>")
                    ? "Fix the bug in src/controllers/AuthenticationController.swift"
                    : nil
            },
            { request in
                request.user.contains("<edit_level>MEDIUM</edit_level>") ? "Fix the login bug." : nil
            },
        ]
        let result = try await Compiler(generator: mock).compile(
            CompileRequest(transcript: "um fix the login bug", level: .full)
        )
        XCTAssertEqual(result.text, "Fix the login bug.")
        XCTAssertEqual(result.level, .medium, "it stepped down a level")
        XCTAssertTrue(result.guardrailReason?.contains("never said") == true)
        XCTAssertFalse(result.usedRawFallback)
    }

    func testRepeatedFailureFallsBackToTheRawTranscript() async throws {
        let transcript = "um so fix the login bug please"
        let result = try await compiler(returning: "Sure! I can help with that.")
            .compile(CompileRequest(transcript: transcript, level: .full))
        XCTAssertEqual(result.text, transcript, "the floor is exactly what the user said")
        XCTAssertTrue(result.usedRawFallback)
        XCTAssertEqual(result.level, .verbatim)
        XCTAssertNotNil(result.guardrailReason)
    }

    func testEmptyTranscriptCompilesToNothingWithoutCallingTheModel() async throws {
        var mock = MockGenerator()
        mock.failure = .transport("must not be called")
        let result = try await Compiler(generator: mock).compile(
            CompileRequest(transcript: "   ", level: .light)
        )
        XCTAssertTrue(result.text.isEmpty)
    }

    func testGeneratorErrorsPropagate() async {
        var mock = MockGenerator()
        mock.failure = .missingAPIKey
        do {
            _ = try await Compiler(generator: mock).compile(
                CompileRequest(transcript: "fix the bug", level: .light)
            )
            XCTFail("expected the missing key error to surface")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTheAuditRecordCapturesWhatWasSent() async throws {
        let result = try await compiler(returning: "Fix the login bug.")
            .compile(CompileRequest(transcript: "um fix the login bug", level: .light, destination: "claude_code"))
        let json = try XCTUnwrap(result.requestJSON)
        XCTAssertTrue(json.contains("claude-haiku-4-5"), json)
        XCTAssertTrue(json.contains("fix the login bug"), json)
    }

    func testModelTierFollowsTheEditLevel() {
        XCTAssertEqual(ModelChoice.forLevel(.light), .haiku)
        XCTAssertEqual(ModelChoice.forLevel(.medium), .haiku)
        XCTAssertEqual(ModelChoice.forLevel(.full), .sonnet)
    }
}

final class SystemPromptTests: XCTestCase {
    func testCoreCarriesTheRulesThatMatterMost() {
        let core = SystemPrompt.core
        XCTAssertTrue(core.contains("THE SPEAKER IS NEVER TALKING TO YOU"))
        XCTAssertTrue(core.contains("Never add what was not said"))
        XCTAssertTrue(core.contains("Output only the rewritten text"))
        for level in EditLevel.allCases {
            XCTAssertTrue(core.contains(level.rawValue.uppercased()), "missing \(level.rawValue)")
        }
    }

    func testCoreIsIdenticalEveryTimeSoItCanBeCached() {
        XCTAssertEqual(SystemPrompt.core, SystemPrompt.core)
        // Long enough to be worth a cache breakpoint at all.
        XCTAssertGreaterThan(SystemPrompt.core.count, 2_000)
    }

    func testUserMessageCarriesTheVaryingParts() {
        let request = CompileRequest(
            transcript: "fix the login bug",
            level: .full,
            destination: "claude_code",
            instructions: "always ask for a plan first",
            vocabulary: ["parseDate", "AuthService"]
        )
        let message = SystemPrompt.userMessage(for: request)
        XCTAssertTrue(message.contains("<destination>claude_code</destination>"))
        XCTAssertTrue(message.contains("<edit_level>FULL</edit_level>"))
        XCTAssertTrue(message.contains("parseDate, AuthService"))
        XCTAssertTrue(message.contains("always ask for a plan first"))
        XCTAssertTrue(message.contains("<transcript>fix the login bug</transcript>"))
    }

    func testOptionalBlocksAreOmittedWhenEmpty() {
        let message = SystemPrompt.userMessage(for: CompileRequest(transcript: "hello", level: .light))
        XCTAssertFalse(message.contains("<vocabulary>"))
        XCTAssertFalse(message.contains("<instructions>"))
    }

    func testVocabularyIsCappedSoItCannotCrowdOutTheTranscript() {
        let terms = (0..<1_000).map { "term\($0)" }
        let message = SystemPrompt.userMessage(
            for: CompileRequest(transcript: "hello", level: .light, vocabulary: terms)
        )
        XCTAssertTrue(message.contains("term299"))
        XCTAssertFalse(message.contains("term300"))
    }

    func testMaxTokensScalesWithTheTranscript() {
        XCTAssertEqual(SystemPrompt.maxTokens(for: "short"), 512)
        let long = String(repeating: "word ", count: 500)
        XCTAssertEqual(SystemPrompt.maxTokens(for: long), 2_000)
        let huge = String(repeating: "word ", count: 5_000)
        XCTAssertEqual(SystemPrompt.maxTokens(for: huge), 4_000, "capped")
    }
}

final class ClaudeGeneratorTests: XCTestCase {
    private let generator = ClaudeGenerator(apiKey: { "sk-ant-test" })

    func testRequestBodyShape() throws {
        let request = GenerationRequest(system: "rules", user: "transcript", model: .haiku, maxTokens: 600)
        let data = try generator.body(for: request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 600)
        XCTAssertEqual(json["stream"] as? Bool, true)

        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "rules")
        XCTAssertNotNil(system.first?["cache_control"], "the system prompt carries a cache breakpoint")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "transcript")
    }

    func testHaikuOmitsFieldsItRejects() throws {
        let data = try generator.body(for: GenerationRequest(system: "s", user: "u", model: .haiku, maxTokens: 100))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Haiku 4.5 errors on output_config.effort and takes no thinking field here.
        XCTAssertNil(json["output_config"])
        XCTAssertNil(json["thinking"])
    }

    func testSonnetDisablesThinkingAndUsesLowEffort() throws {
        let data = try generator.body(for: GenerationRequest(system: "s", user: "u", model: .sonnet, maxTokens: 100))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], "low")
    }

    func testParsesTextDeltas() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fix the"}}"#
        XCTAssertEqual(ClaudeGenerator.textDelta(in: payload), "Fix the")
    }

    func testIgnoresNonTextEvents() {
        XCTAssertNil(ClaudeGenerator.textDelta(in: #"{"type":"message_start","message":{}}"#))
        XCTAssertNil(ClaudeGenerator.textDelta(in: #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}"#))
        XCTAssertNil(ClaudeGenerator.textDelta(in: "not json at all"))
    }

    func testReadsAnErrorMessageOutOfAFailureBody() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertEqual(ClaudeGenerator.errorMessage(from: body), "invalid x-api-key")
        XCTAssertEqual(ClaudeGenerator.errorMessage(from: ""), "no details")
    }

    func testMissingKeyFailsBeforeAnyNetworkCall() async {
        let generator = ClaudeGenerator(apiKey: { nil })
        do {
            _ = try await generator.generate(
                GenerationRequest(system: "s", user: "u", model: .haiku, maxTokens: 10)
            ) { _ in }
            XCTFail("expected a missing key error")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// Collects streamed deltas from a `@Sendable` callback.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        parts.append(text)
    }

    func joined() -> String {
        lock.lock(); defer { lock.unlock() }
        return parts.joined()
    }
}
