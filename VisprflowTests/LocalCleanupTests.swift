import XCTest
@testable import Visprflow

final class LocalCleanupTests: XCTestCase {
    func testRemovesFillers() {
        XCTAssertEqual(LocalCleanup.clean("um fix the uh login bug"), "Fix the login bug.")
    }

    func testCollapsesStutters() {
        XCTAssertEqual(LocalCleanup.clean("can you send me the the figma link"),
                       "Can you send me the figma link?")
    }

    func testKeepsLegitimateDoubledWords() {
        // "had had" and "that that" are real English, not stutters.
        XCTAssertTrue(LocalCleanup.clean("the report that that team wrote").contains("that that"))
        XCTAssertTrue(LocalCleanup.clean("he had had enough").contains("had had"))
    }

    func testDoesNotRemoveDiscourseWordsThatCarryMeaning() {
        // "like" and "actually" change meaning often enough that removing them is not cleanup.
        let cleaned = LocalCleanup.clean("I actually liked it and it works like a charm")
        XCTAssertTrue(cleaned.contains("actually"))
        XCTAssertTrue(cleaned.contains("like a charm"))
    }

    func testAppliesSpokenPunctuation() {
        XCTAssertEqual(LocalCleanup.clean("ship it comma then rest period"), "Ship it, then rest.")
    }

    func testAppliesSpokenLayout() {
        let cleaned = LocalCleanup.clean("first point new paragraph second point")
        XCTAssertTrue(cleaned.contains("\n\n"), cleaned)
        XCTAssertTrue(cleaned.hasPrefix("First point"))
    }

    func testCapitalisesSentencesAndThePronounI() {
        XCTAssertEqual(LocalCleanup.clean("i think it works. i'll check again"),
                       "I think it works. I'll check again.")
    }

    func testAddsAQuestionMarkForQuestions() {
        XCTAssertEqual(LocalCleanup.clean("what is the difference between a mutex and a semaphore"),
                       "What is the difference between a mutex and a semaphore?")
        XCTAssertEqual(LocalCleanup.clean("how do I run the tests"), "How do I run the tests?")
    }

    func testLeavesCommandsAlone() {
        // A path or a flag means this is not prose; adding a full stop would break it.
        XCTAssertEqual(LocalCleanup.clean("git push --force-with-lease"), "Git push --force-with-lease")
        XCTAssertFalse(LocalCleanup.clean("run make install in src/app").hasSuffix("."))
    }

    func testAlreadyCleanTextIsBarelyTouched() {
        XCTAssertEqual(LocalCleanup.clean("The build is green."), "The build is green.")
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(LocalCleanup.clean(""), "")
        XCTAssertEqual(LocalCleanup.clean("um uh"), "")
    }

    func testWordOrderAndWordingAreNeverChanged() {
        // The promise of a local clean is that nothing but noise is removed.
        let transcript = "deploy the worker to staging and watch the queue depth"
        let cleaned = LocalCleanup.clean(transcript).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        XCTAssertEqual(cleaned, transcript)
    }

    // MARK: Escalation

    func testDetectsSelfCorrectionsItCannotResolve() {
        for transcript in [
            "the call is at nine no wait eleven thirty",
            "send it to Priya, scratch that, send it to the whole team",
            "use the session refresh, I mean the token refresh",
        ] {
            XCTAssertTrue(LocalCleanup.needsModel(transcript), "missed: \(transcript)")
        }
    }

    func testOrdinarySpeechDoesNotEscalate() {
        for transcript in [
            "fix the login bug in the auth folder",
            "I actually enjoyed the talk",
            "wait for the build to finish before deploying",
        ] {
            XCTAssertFalse(LocalCleanup.needsModel(transcript), "false escalation: \(transcript)")
        }
    }

    func testLocalGeneratorReadsTheTranscriptOutOfTheUserMessage() async throws {
        let request = GenerationRequest(
            system: "rules",
            user: SystemPrompt.userMessage(for: CompileRequest(transcript: "um fix the bug", level: .light)),
            model: .haiku,
            maxTokens: 100
        )
        let output = try await LocalGenerator().generate(request) { _ in }
        XCTAssertEqual(output, "Fix the bug.")
    }
}

final class ProviderRoutingTests: XCTestCase {
    /// A generator that records that it was used.
    private struct Marker: TextGenerating {
        let name: String
        func generate(
            _ request: GenerationRequest,
            onDelta: @escaping @Sendable (String) -> Void
        ) async throws -> String {
            onDelta(name)
            return name
        }
    }

    private func route(
        _ policy: ProviderPolicy,
        level: EditLevel,
        transcript: String = "fix the login bug"
    ) async throws -> String {
        let generator = RoutingGenerator(
            policy: policy,
            level: level,
            local: Marker(name: "local"),
            subscription: Marker(name: "subscription"),
            api: Marker(name: "api")
        )
        let request = GenerationRequest(
            system: "rules",
            user: SystemPrompt.userMessage(for: CompileRequest(transcript: transcript, level: level)),
            model: .haiku,
            maxTokens: 100
        )
        return try await generator.generate(request) { _ in }
    }

    func testDefaultKeepsLightEditsOnTheMachine() async throws {
        let used = try await route(.default, level: .light)
        XCTAssertEqual(used, "local", "the common path must be instant and free")
    }

    func testDefaultSendsFullCompilesToTheSubscription() async throws {
        let full = try await route(.default, level: .full)
        let medium = try await route(.default, level: .medium)
        XCTAssertEqual(full, "subscription")
        XCTAssertEqual(medium, "subscription")
    }

    func testAllApiPolicyUsesTheApiEverywhere() async throws {
        let light = try await route(.allAPI, level: .light)
        let full = try await route(.allAPI, level: .full)
        XCTAssertEqual(light, "api")
        XCTAssertEqual(full, "api")
    }

    func testOfflinePolicyNeverLeavesTheMachine() async throws {
        let light = try await route(.offline, level: .light)
        let full = try await route(.offline, level: .full)
        XCTAssertEqual(light, "local")
        XCTAssertEqual(full, "local")
    }

    /// The important one: local cleanup must not silently mangle a self-correction.
    func testSelfCorrectionEscalatesFromLocalToTheCompileProvider() async throws {
        let used = try await route(
            .default,
            level: .light,
            transcript: "the call is at nine no wait eleven thirty"
        )
        XCTAssertEqual(used, "subscription", "a correction needs judgement, so it goes to a model")
    }

    func testSelfCorrectionStaysLocalWhenThatIsAllTheUserAllows() async throws {
        let used = try await route(
            .offline,
            level: .light,
            transcript: "the call is at nine no wait eleven thirty"
        )
        XCTAssertEqual(used, "local", "an offline policy is honoured even when a model would be better")
    }

    func testPolicySurvivesEncoding() throws {
        let policy = ProviderPolicy(fastPath: .local, compilePath: .apiKey)
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(ProviderPolicy.self, from: data), policy)
    }

    func testEveryProviderExplainsItself() {
        for choice in ProviderChoice.allCases {
            XCTAssertFalse(choice.displayName.isEmpty)
            XCTAssertFalse(choice.summary.isEmpty)
            XCTAssertFalse(choice.latencyNote.isEmpty)
        }
    }
}

final class ClaudeCLIGeneratorTests: XCTestCase {
    func testArgumentsStripEverythingNotNeededForARewrite() throws {
        let arguments = ClaudeCLIGenerator.arguments(
            prompt: "the transcript",
            system: "rules",
            model: "claude-haiku-4-5"
        )
        XCTAssertTrue(arguments.contains("-p"))
        XCTAssertTrue(arguments.contains("--strict-mcp-config"), "no MCP servers")
        XCTAssertTrue(arguments.contains("--no-session-persistence"), "no session written to disk")
        XCTAssertTrue(arguments.contains("--exclude-dynamic-system-prompt-sections"))
        XCTAssertTrue(arguments.contains("stream-json"), "streamed so the overlay fills in")
        XCTAssertTrue(arguments.contains("Bash"), "tools must be disallowed: this is a rewrite, not an agent")

        // Regression: --disallowed-tools is variadic, so a prompt placed after it is
        // swallowed as another tool name and the CLI exits saying it got no input.
        let promptIndex = try? XCTUnwrap(arguments.firstIndex(of: "the transcript"))
        let flagIndex = try? XCTUnwrap(arguments.firstIndex(of: "--disallowed-tools"))
        XCTAssertEqual(arguments.firstIndex(of: "-p").map { $0 + 1 }, promptIndex,
                       "the prompt must sit immediately after -p")
        if let promptIndex, let flagIndex {
            XCTAssertLessThan(promptIndex, flagIndex, "the variadic flag must come last")
        }
    }

    func testParsesATextDeltaOutOfTheWrappedStream() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fix the"}}}"#
        XCTAssertEqual(ClaudeCLIGenerator.textDelta(in: line), "Fix the")
    }

    func testIgnoresTheCliSOwnSystemEvents() {
        XCTAssertNil(ClaudeCLIGenerator.textDelta(in: #"{"type":"system","subtype":"init"}"#))
        XCTAssertNil(ClaudeCLIGenerator.textDelta(in: "not json"))
    }

    func testDetectsAReportedFailure() {
        let line = #"{"type":"result","subtype":"error","is_error":true,"result":"Not signed in"}"#
        XCTAssertEqual(ClaudeCLIGenerator.errorMessage(in: line), "Not signed in")
        XCTAssertNil(ClaudeCLIGenerator.errorMessage(in: #"{"type":"result","is_error":false,"result":"ok"}"#))
    }

    func testFindsTheInstalledCommandOnThisMachine() throws {
        // The app is a GUI process and does not inherit the shell PATH, so the standard
        // install locations have to be searched explicitly.
        let path = try XCTUnwrap(ClaudeCLIGenerator.findExecutable(),
                                 "claude should be discoverable at a standard location")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }
}
