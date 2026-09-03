import XCTest
@testable import Visprflow

final class RepoVocabularyTests: XCTestCase {
    func testFindsCompoundIdentifiers() {
        let source = """
        func parseDate(from raw: String) -> Date? {
            let MAX_RETRIES = 3
            return AuthMiddleware.shared.decode(raw)
        }
        """
        let terms = Set(RepoVocabulary.identifiers(in: source))
        XCTAssertTrue(terms.contains("parseDate"))
        XCTAssertTrue(terms.contains("MAX_RETRIES"))
        XCTAssertTrue(terms.contains("AuthMiddleware"))
    }

    func testSkipsLanguageKeywordsAndShortWords() {
        let terms = Set(RepoVocabulary.identifiers(in: "public func let var return self true nil for"))
        XCTAssertTrue(terms.isEmpty, "got \(terms)")
    }

    func testSkipsOrdinaryShortWords() {
        // Plain lowercase words are only kept when they are long enough to be distinctive.
        let terms = Set(RepoVocabulary.identifiers(in: "the quick brown fox jumps"))
        XCTAssertTrue(terms.isEmpty, "got \(terms)")
    }

    func testKeepsLongLowercaseDomainWords() {
        let terms = Set(RepoVocabulary.identifiers(in: "transcription middleware"))
        XCTAssertTrue(terms.contains("transcription"))
        XCTAssertTrue(terms.contains("middleware"))
    }

    func testEmptySourceYieldsNothing() {
        XCTAssertTrue(RepoVocabulary.identifiers(in: "").isEmpty)
    }

    /// The end-to-end harvest, against a real repository built for the test.
    func testHarvestsFileNamesAndChangedFileIdentifiers() throws {
        let repo = URL(filePath: NSTemporaryDirectory())
            .appending(path: "visprflow-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        try "let x = 1".write(to: repo.appending(path: "AuthMiddleware.swift"), atomically: true, encoding: .utf8)
        try """
        struct TokenRefresher {
            func refreshAccessToken() {}
        }
        """.write(to: repo.appending(path: "session.swift"), atomically: true, encoding: .utf8)

        func git(_ arguments: [String]) {
            _ = WorkspaceProbe.run("/usr/bin/git", ["-C", repo.path] + arguments)
        }
        git(["init", "-q"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        git(["add", "."])
        git(["commit", "-q", "-m", "first"])

        let context = WorkspaceProbe.probe(directory: repo)
        XCTAssertNotNil(context.gitBranch, "the probe should read the branch")

        // Change a file so it lands in changedFiles and its identifiers are harvested.
        try """
        struct TokenRefresher {
            func refreshAccessToken() {}
            func revokeRefreshToken() {}
        }
        """.write(to: repo.appending(path: "session.swift"), atomically: true, encoding: .utf8)

        let changed = WorkspaceProbe.probe(directory: repo)
        XCTAssertTrue(changed.changedFiles.contains("session.swift"), "got \(changed.changedFiles)")

        let terms = Set(RepoVocabulary.harvest(changed))
        XCTAssertTrue(terms.contains("AuthMiddleware"), "file names become vocabulary: \(terms)")
        XCTAssertTrue(terms.contains("revokeRefreshToken"), "identifiers from edited files: \(terms)")
        XCTAssertLessThanOrEqual(terms.count, RepoVocabulary.limit)
    }

    func testHarvestOfANonRepositoryIsEmptyRatherThanAnError() {
        let context = WorkspaceProbe.probe(directory: URL(filePath: "/"))
        XCTAssertTrue(RepoVocabulary.harvest(context).isEmpty || context.gitBranch == nil)
    }

    func testProbeWithoutADirectoryIsEmpty() {
        XCTAssertTrue(RepoVocabulary.harvest(.none).isEmpty)
        XCTAssertTrue(WorkspaceContext.none.isEmpty)
    }
}

final class ProcessTreeTests: XCTestCase {
    private let table: [ProcessTree.Entry] = [
        .init(pid: 100, parent: 1, command: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        .init(pid: 200, parent: 100, command: "-zsh"),
        .init(pid: 300, parent: 200, command: "/opt/homebrew/bin/claude"),
        .init(pid: 400, parent: 1, command: "/usr/bin/unrelated"),
    ]

    func testFindsAnAgentBeneathTheTerminal() {
        XCTAssertEqual(ProcessTree.agentCommand(under: 100, entries: table), "claude")
    }

    func testFallsBackToTheDeepestShellWhenNoAgentIsRunning() {
        let shellsOnly = table.filter { $0.pid != 300 }
        let foreground = ProcessTree.foreground(under: 100, entries: shellsOnly)
        XCTAssertEqual(foreground?.command, "zsh")
        XCTAssertEqual(foreground?.pid, 200)
        XCTAssertFalse(foreground?.isAgent ?? true)
        XCTAssertNil(ProcessTree.agentCommand(under: 100, entries: shellsOnly))
    }

    func testUnrelatedProcessesAreNotConsidered() {
        XCTAssertNil(ProcessTree.agentCommand(under: 999, entries: table))
    }

    /// Regression: npm installs Claude Code as `node .../claude`, so matching the executable
    /// name alone would see only `node` and treat the terminal as a plain shell.
    func testFindsAnAgentRunningUnderAnInterpreter() {
        let npmTable: [ProcessTree.Entry] = [
            .init(pid: 100, parent: 1, command: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            .init(pid: 200, parent: 100, command: "-zsh"),
            .init(pid: 300, parent: 200, command: "node /Users/x/.nvm/versions/node/v22/bin/claude"),
        ]
        XCTAssertEqual(ProcessTree.agentCommand(under: 100, entries: npmTable), "claude")
    }

    func testEffectiveNameLooksPastAnInterpreter() {
        XCTAssertEqual(ProcessTree.effectiveName(of: "node /opt/homebrew/bin/claude"), "claude")
        XCTAssertEqual(ProcessTree.effectiveName(of: "python3 -u /usr/local/bin/aider"), "aider")
        XCTAssertEqual(ProcessTree.effectiveName(of: "/bin/zsh"), "zsh")
        XCTAssertEqual(ProcessTree.effectiveName(of: "node"), "node", "an interpreter alone is itself")
    }

    func testBasenameStripsPathsAndLoginShellDashes() {
        XCTAssertEqual(ProcessTree.basename("/opt/homebrew/bin/claude"), "claude")
        XCTAssertEqual(ProcessTree.basename("-zsh"), "zsh")
        XCTAssertEqual(ProcessTree.basename("Codex"), "codex")
    }

    func testParsesPsOutput() {
        let output = """
          123    1 /bin/zsh
          456  123 claude --resume
        """
        let entries = ProcessTree.parse(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].pid, 123)
        XCTAssertEqual(entries[1].parent, 123)
        XCTAssertEqual(entries[1].command, "claude --resume", "arguments are kept whole")
    }

    func testParsingIgnoresMalformedLines() {
        XCTAssertTrue(ProcessTree.parse("garbage\n\n  x y z\n").isEmpty)
    }

    func testRealSnapshotIncludesThisProcess() {
        // Cheap sanity check that the ps invocation and parsing work on this machine.
        let entries = ProcessTree.snapshot()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}
