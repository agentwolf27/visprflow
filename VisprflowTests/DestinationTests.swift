import XCTest
@testable import Visprflow

final class DestinationResolverTests: XCTestCase {
    // MARK: Terminals

    func testTerminalRunningClaudeIsACodingAgent() {
        let context = FocusContext(bundleIdentifier: "com.googlecode.iterm2", terminalProcess: "claude")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "claude_code")
    }

    func testTerminalRunningCodexIsItsOwnDestination() {
        let context = FocusContext(bundleIdentifier: "com.mitchellh.ghostty", terminalProcess: "codex")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "codex")
    }

    func testTerminalProcessPathIsReducedToItsName() {
        let context = FocusContext(bundleIdentifier: "com.apple.Terminal", terminalProcess: "/opt/homebrew/bin/claude")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "claude_code")
    }

    func testPlainShellIsVerbatim() {
        let context = FocusContext(bundleIdentifier: "com.apple.Terminal", terminalProcess: "zsh")
        let destination = DestinationResolver.resolve(context)
        XCTAssertEqual(destination.id, "shell")
        XCTAssertEqual(destination.defaultLevel, .verbatim, "a shell command must never be reformatted")
    }

    func testTerminalWithoutProcessInformationFallsBackToShell() {
        // Safer to under-edit a sentence than to rewrite someone's command.
        let context = FocusContext(bundleIdentifier: "dev.warp.Warp-Stable")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "shell")
    }

    // MARK: Browsers

    func testClaudeAiIsAChatDestination() {
        let context = FocusContext(bundleIdentifier: "com.google.Chrome", browserURL: "https://claude.ai/chat/abc")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "chat")
    }

    func testSlackInABrowserIsAMessage() {
        let context = FocusContext(bundleIdentifier: "company.thebrowser.Browser", browserURL: "https://app.slack.com/client/T1/C2")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "message")
    }

    func testGmailIsEmail() {
        let context = FocusContext(bundleIdentifier: "com.apple.Safari", browserURL: "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "email")
    }

    func testUnknownSiteIsJustADocument() {
        let context = FocusContext(bundleIdentifier: "com.apple.Safari", browserURL: "https://example.com/form")
        XCTAssertEqual(DestinationResolver.resolve(context).id, "document")
    }

    func testBrowserWithNoUrlIsADocument() {
        XCTAssertEqual(DestinationResolver.resolve(FocusContext(bundleIdentifier: "com.apple.Safari")).id, "document")
    }

    func testHostParsingToleratesAMissingScheme() {
        XCTAssertEqual(DestinationResolver.host(of: "claude.ai/chat"), "claude.ai")
        XCTAssertEqual(DestinationResolver.host(of: "https://CLAUDE.AI/x"), "claude.ai")
        XCTAssertNil(DestinationResolver.host(of: ""))
        XCTAssertNil(DestinationResolver.host(of: nil))
    }

    // MARK: Apps

    func testNativeAppsMapToTheirDestinations() {
        let cases: [(String, String)] = [
            ("com.todesktop.230313mzl4w4u92", "cursor"),
            ("com.microsoft.VSCode", "cursor"),
            ("com.tinyspeck.slackmacgap", "message"),
            ("com.apple.MobileSMS", "message"),
            ("com.apple.mail", "email"),
            ("com.superhuman.electron", "email"),
            ("com.apple.Notes", "document"),
        ]
        for (bundle, expected) in cases {
            XCTAssertEqual(DestinationResolver.resolve(FocusContext(bundleIdentifier: bundle)).id, expected, bundle)
        }
    }

    func testUnknownAppFallsBackToDocument() {
        XCTAssertEqual(DestinationResolver.resolve(FocusContext(bundleIdentifier: "com.example.Unknown")).id, "document")
        XCTAssertEqual(DestinationResolver.resolve(.unknown).id, "document")
    }

    func testEveryDestinationIsFindableByIdentifier() {
        for destination in Destination.all {
            XCTAssertEqual(Destination.named(destination.id)?.id, destination.id)
        }
        XCTAssertNil(Destination.named("nope"))
    }

    func testCodingAgentsPreviewBeforeInserting() {
        // A wrong prompt sent to an agent costs more than a keystroke.
        for destination in [Destination.claudeCode, .cursor, .codex] {
            XCTAssertTrue(destination.requiresPreview, destination.id)
        }
        for destination in [Destination.message, .document, .shell] {
            XCTAssertFalse(destination.requiresPreview, destination.id)
        }
    }
}

final class LevelHeuristicTests: XCTestCase {
    private let short = "fix the login bug"
    private let long = String(repeating: "the retry logic needs an exponential backoff and a cap ", count: 6)

    func testShortUtteranceIsOnlyCleanedUp() {
        let decision = LevelHeuristic.decide(transcript: short, destination: .claudeCode)
        XCTAssertEqual(decision.level, .light, "a one-line ask does not need restructuring")
    }

    func testLongRequestToACodingAgentIsCompiled() {
        let decision = LevelHeuristic.decide(transcript: long, destination: .claudeCode)
        XCTAssertEqual(decision.level, .full)
    }

    func testShellIsAlwaysVerbatim() {
        XCTAssertEqual(LevelHeuristic.decide(transcript: long, destination: .shell).level, .verbatim)
        XCTAssertEqual(LevelHeuristic.decide(transcript: short, destination: .shell).level, .verbatim)
    }

    func testMessagesStayLightHoweverLong() {
        XCTAssertEqual(LevelHeuristic.decide(transcript: long, destination: .message).level, .light)
    }

    func testChatUsesMediumUntilItGetsLong() {
        let medium = String(repeating: "one more clause about the problem ", count: 6) // ~36 words
        XCTAssertEqual(LevelHeuristic.decide(transcript: medium, destination: .chat).level, .medium)
        let veryLong = String(repeating: "one more clause about the problem ", count: 12) // ~72 words
        XCTAssertEqual(LevelHeuristic.decide(transcript: veryLong, destination: .chat).level, .full)
    }

    func testModifierOverrideWins() {
        let decision = LevelHeuristic.decide(transcript: long, destination: .claudeCode, override: .verbatim)
        XCTAssertEqual(decision.level, .verbatim)
    }

    // MARK: Spoken commands

    func testSpokenVerbatimCommandIsStripped() {
        let decision = LevelHeuristic.decide(transcript: "verbatim: git push --force-with-lease", destination: .chat)
        XCTAssertEqual(decision.level, .verbatim)
        XCTAssertEqual(decision.transcript, "git push --force-with-lease")
    }

    func testSpokenPromptModeForcesFull() {
        let decision = LevelHeuristic.decide(transcript: "prompt mode add retries to the uploader", destination: .message)
        XCTAssertEqual(decision.level, .full)
        XCTAssertEqual(decision.transcript, "add retries to the uploader")
    }

    func testCommandWordsInTheMiddleAreContent() {
        // "verbatim" only counts at the very start of the utterance.
        let decision = LevelHeuristic.decide(transcript: "tell them to quote me verbatim on this", destination: .message)
        XCTAssertEqual(decision.level, .light)
        XCTAssertEqual(decision.transcript, "tell them to quote me verbatim on this")
    }

    func testCommandWordRunningIntoAnotherWordIsContent() {
        // "exactly right" is dictation, not a verbatim instruction.
        XCTAssertNil(LevelHeuristic.spokenCommand(in: "exactlyright now please"))
        let decision = LevelHeuristic.decide(transcript: "exactly right, ship it", destination: .message)
        XCTAssertEqual(decision.level, .verbatim, "“exactly,” at the start does read as a command")
    }

    func testBareCommandWithNothingAfterItIsContent() {
        // Otherwise saying just "verbatim" would insert nothing at all.
        XCTAssertNil(LevelHeuristic.spokenCommand(in: "verbatim"))
        XCTAssertEqual(LevelHeuristic.decide(transcript: "verbatim", destination: .message).transcript, "verbatim")
    }

    func testDecisionAlwaysExplainsItself() {
        for destination in Destination.all {
            let decision = LevelHeuristic.decide(transcript: long, destination: destination)
            XCTAssertFalse(decision.reason.isEmpty, destination.id)
        }
    }
}
