import XCTest
@testable import Visprflow

/// Drives the real `claude` command line tool, which spends the user's Claude subscription
/// rather than API credits. Opt in, because each run costs real quota:
///
///     make verify-subscription
final class SubscriptionIntegrationTests: XCTestCase {
    private static let isEnabled = ProcessInfo.processInfo.environment["VISPRFLOW_CLI"] == "1"

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.isEnabled, "set VISPRFLOW_CLI=1 to run the subscription tests")
        try XCTSkipUnless(ClaudeCLIGenerator.isAvailable, "the claude command is not installed")
    }

    func testCompilesARamblingRequestThroughTheSubscription() async throws {
        let transcript = """
        okay so um the login thing is broken again, users get logged out like after the token \
        expires, I think it's in the auth folder, src slash auth, the refresh thing, no wait the \
        token refresh not the session refresh, can you look at that and uh write a test that \
        reproduces it first then fix it, don't touch the session stuff
        """

        let compiler = Compiler(generator: ClaudeCLIGenerator())
        let started = ContinuousClock.now
        let result = try await compiler.compile(
            CompileRequest(transcript: transcript, level: .full, destination: "claude_code")
        )
        let seconds = Trace.milliseconds(ContinuousClock.now - started) / 1000

        print("SUBSCRIPTION: \(String(format: "%.1f", seconds))s -> \(result.text)")

        XCTAssertFalse(result.usedRawFallback, "the guardrails rejected it: \(result.guardrailReason ?? "")")
        let lowered = result.text.lowercased()
        // The self-correction must have been applied: the token refresh survives, the
        // discarded session refresh does not come back as the subject.
        XCTAssertTrue(lowered.contains("token refresh"), result.text)
        // Fillers must be gone.
        XCTAssertFalse(lowered.contains(" um "), result.text)
        XCTAssertFalse(lowered.contains(" uh "), result.text)
        // The constraint the user actually spoke must survive.
        XCTAssertTrue(lowered.contains("session"), "the don't-touch constraint was dropped: \(result.text)")
    }

    func testDoesNotAnswerAQuestionItIsAskedToRewrite() async throws {
        // The single most common failure in this category: the model answers instead of
        // rewriting. Worth spending real quota to check against the live model.
        let result = try await Compiler(generator: ClaudeCLIGenerator()).compile(
            CompileRequest(
                transcript: "whats the difference between a mutex and a semaphore",
                level: .light,
                destination: "chat"
            )
        )
        print("SUBSCRIPTION question: \(result.text)")
        XCTAssertTrue(result.text.count < 120, "it answered rather than rewrote: \(result.text)")
        XCTAssertTrue(result.text.lowercased().contains("difference"), result.text)
    }

    func testReportsAMissingExecutableClearly() async {
        let generator = ClaudeCLIGenerator(executable: "/nonexistent/claude")
        do {
            _ = try await generator.generate(
                GenerationRequest(system: "s", user: "u", model: .haiku, maxTokens: 10)
            ) { _ in }
            XCTFail("expected a clear failure")
        } catch let error as GenerationError {
            guard case let .transport(message) = error else {
                return XCTFail("expected a transport error, got \(error)")
            }
            XCTAssertTrue(message.contains("not found"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
