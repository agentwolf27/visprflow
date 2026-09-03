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

        // Read on a background queue so a large output cannot deadlock the pipe.
        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while process.isRunning, Date() < deadline {
            data.append(handle.availableData)
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            Log.app.error("Timed out running \(executable, privacy: .public)")
            return ""
        }
        data.append(handle.readDataToEndOfFile())
        return String(decoding: data, as: UTF8.self)
    }
}
