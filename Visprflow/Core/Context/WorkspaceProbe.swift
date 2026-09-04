import Foundation

/// What the project under the cursor looks like right now.
struct WorkspaceContext: Sendable, Equatable {
    var directory: URL?
    var gitBranch: String?
    /// Paths changed against the branch point, most useful for vocabulary.
    var changedFiles: [String] = []

    static let none = WorkspaceContext()

    var isEmpty: Bool { directory == nil }
}

/// Finds the working directory behind a terminal window, and reads the repository there.
///
/// This is what lets a dictation know the project's own words. It is the difference between
/// the transcript coming back as "aut midway" and as "auth middleware".
enum WorkspaceProbe {
    /// Working directory of a process, via lsof.
    static func workingDirectory(of pid: Int32) -> URL? {
        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        // Output is one field per line; the path line starts with "n".
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            guard !path.isEmpty else { continue }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return nil
    }

    /// Reads the repository at `directory`, if there is one.
    static func probe(directory: URL) -> WorkspaceContext {
        var context = WorkspaceContext(directory: directory)

        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return context }
        context.gitBranch = branch

        // Files changed against the upstream branch point, falling back to the working tree.
        var changed = git(["diff", "--name-only", "HEAD"], in: directory)
        if changed.isEmpty {
            changed = git(["diff", "--name-only", "HEAD~5..HEAD"], in: directory)
        }
        context.changedFiles = changed
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        return context
    }

    static func git(_ arguments: [String], in directory: URL) -> String {
        run("/usr/bin/git", ["-C", directory.path] + arguments)
    }

    /// Runs a command and returns stdout, or an empty string on any failure.
    /// Bounded so a hung command cannot stall a dictation.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1.5) -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        // The obvious loop here — `while process.isRunning, Date() < deadline { append(
        // handle.availableData) }` — does not work, and its timeout is an illusion:
        // `availableData` blocks until there is data or EOF, so a child that prints nothing and
        // never exits (an `osascript` querying a beachballed browser is the usual one) blocks
        // inside that call and the deadline is never evaluated again. That hung the dictation on
        // "Transcribing…" forever and leaked a thread every time.
        //
        // Instead the blocking read happens on a background queue and the wait is a semaphore
        // that genuinely expires. Terminating the child closes the pipe, which unblocks the
        // reader, so nothing is left parked.
        let handle = pipe.fileHandleForReading
        let output = Collected()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            output.append(handle.readDataToEndOfFile())
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Closing the pipe releases the reader; wait briefly so the child is reaped.
            _ = finished.wait(timeout: .now() + 0.5)
            Log.app.error("Timed out running \(executable, privacy: .public)")
            return ""
        }

        process.waitUntilExit()
        return String(decoding: output.data, as: UTF8.self)
    }

    /// Accumulates pipe output written from the reader queue and read from the caller.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }
}
