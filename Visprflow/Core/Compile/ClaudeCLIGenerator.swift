import Foundation

/// Rewrites through the `claude` command line tool, which uses your Claude subscription
/// instead of API credits.
///
/// The trade-off, measured on this machine: about 3 seconds to the first word and 6 to 10 to
/// finish, against roughly 0.7 and 1.5 through the API. The quality is identical because it is
/// the same model. That makes this the right choice for a full compile, which you preview
/// anyway, and the wrong one for cleaning up a one-line message, which is why LIGHT edits are
/// handled locally instead.
struct ClaudeCLIGenerator: TextGenerating {
    /// Where the CLI lives. Resolved once at startup rather than per dictation.
    var executable: String
    /// Working directory for the CLI. A directory with no project config starts faster and
    /// keeps the rewrite free of any repository's own instructions.
    var workingDirectory: URL

    init(
        executable: String = ClaudeCLIGenerator.findExecutable() ?? "/usr/local/bin/claude",
        workingDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    /// A compile that has produced nothing by now is stuck, not slow. Measured runs finish in
    /// 6-10 s, so this is generous.
    static let timeout: TimeInterval = 60

    /// Whether the CLI is installed and usable.
    static var isAvailable: Bool {
        findExecutable() != nil
    }

    /// Looks for `claude` on the usual paths. A GUI app does not inherit the shell's PATH,
    /// so the standard install locations have to be checked explicitly.
    static func findExecutable() -> String? {
        var candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        // nvm and other version managers install per-version, so search the user's node dirs.
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appending(path: ".claude/local/claude").path)
        let nvm = home.appending(path: ".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for version in versions.sorted().reversed() {
                candidates.append(nvm.appending(path: "\(version)/bin/claude").path)
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Arguments that strip everything the CLI does not need for a one-shot rewrite: no
    /// session on disk, no MCP servers, no tools, no repository instructions, no user hooks.
    ///
    /// The prompt goes immediately after `-p`, and the variadic `--disallowed-tools` goes
    /// last. Putting the prompt at the end makes that flag swallow it as another tool name,
    /// and the CLI then exits complaining that no input was given.
    static func arguments(prompt: String, system: String, model: String) -> [String] {
        [
            "-p", prompt,
            "--system-prompt", system,
            "--model", model,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--strict-mcp-config",
            "--exclude-dynamic-system-prompt-sections",
            "--no-session-persistence",
            // An empty settings object keeps the user's own hooks and plugins out of the
            // dictation path; otherwise every rewrite fires their session hooks.
            "--settings", "{}",
            "--disallowed-tools",
            "Bash", "Read", "Write", "Edit", "Glob", "Grep",
            "WebFetch", "WebSearch", "Task", "TodoWrite", "NotebookEdit",
        ]
    }

    func generate(
        _ request: GenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw GenerationError.transport("The claude command line tool was not found. Install it, or switch to an API key in settings.")
        }

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = Self.arguments(
            prompt: request.user,
            system: request.system,
            model: request.model.identifier
        )
        process.currentDirectoryURL = workingDirectory
        // Closing stdin matters: the CLI otherwise waits three seconds for piped input.
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw GenerationError.transport("Could not run the claude command: \(error.localizedDescription)")
        }

        // Both pipes are drained by readability handlers on background queues. Reading stdout
        // inline blocked a cooperative thread for the whole 6-10 s of a compile, made the
        // cancellation check unreachable until data happened to arrive, and deadlocked outright
        // whenever --verbose filled the 64 KB stderr buffer while we were blocked on stdout.
        let collected = TextAccumulator()
        let errors = TextAccumulator()
        let outHandle = output.fileHandleForReading
        let errHandle = errorPipe.fileHandleForReading

        let lines = LineBuffer()
        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(chunk) {
                if let delta = Self.textDelta(in: line) {
                    collected.append(delta)
                    onDelta(delta)
                }
            }
        }
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errors.append(String(decoding: chunk, as: UTF8.self))
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        // Cancellation and the wall-clock ceiling both have to be able to interrupt a CLI that
        // is waiting on auth or a stalled network, where no output ever arrives.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if finished.wait(timeout: .now() + Self.timeout) == .timedOut {
                        Log.compile.error("The claude command exceeded \(Self.timeout, privacy: .public)s; terminating")
                        process.terminate()
                        _ = finished.wait(timeout: .now() + 1)
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            process.terminate()
        }

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        if Task.isCancelled { throw GenerationError.cancelled }

        let result = collected.value().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            if process.terminationStatus == 0 { throw GenerationError.emptyResponse }
            // Report what the tool actually said. "Not logged in" and a keychain refusal need
            // very different fixes, and guessing between them wastes the user's time.
            let stderr = errors.value().trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "no output" : String(stderr.prefix(300))
            throw GenerationError.transport("The claude command failed (status \(process.terminationStatus)): \(detail)")
        }
        return result
    }

    // MARK: Parsing

    /// Text out of one streamed event. The CLI wraps the API's own events, so the delta sits
    /// under `event` for partial messages and under `message.content` for a finished one.
    static func textDelta(in line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard object["type"] as? String == "stream_event",
              let event = object["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta"
        else { return nil }
        return delta["text"] as? String
    }

    /// A failure reported on the stream, such as not being signed in.
    static func errorMessage(in line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if object["type"] as? String == "result",
           object["is_error"] as? Bool == true {
            return (object["result"] as? String) ?? "The claude command reported an error."
        }
        return nil
    }
}

/// Splits a byte stream into whole lines across chunk boundaries, since a JSON object can be
/// delivered in pieces.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            }
        }
        return lines
    }
}

/// Thread-safe accumulator for streamed text.
private final class TextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ delta: String) {
        lock.lock(); defer { lock.unlock() }
        text += delta
    }

    func value() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}
