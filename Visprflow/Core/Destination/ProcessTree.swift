import Foundation

/// Finds which command is running inside a terminal window.
///
/// This is what separates "you are talking to Claude Code" from "you are typing a shell
/// command", and those two want opposite treatment: one wants a fully structured prompt, the
/// other must not be touched at all. Reading the terminal's descendants is more reliable than
/// guessing from the window title, which every shell formats differently.
enum ProcessTree {
    struct Entry: Sendable, Equatable {
        var pid: Int32
        var parent: Int32
        var command: String
    }

    /// Commands that mean an AI agent is in the foreground of that terminal.
    /// Ordered so a more specific match wins over a shell.
    static let interestingCommands: Set<String> = DestinationResolver.agentProcesses

    /// What is running inside a terminal: the agent if there is one, otherwise the deepest
    /// shell, whose working directory is the one the user is looking at.
    struct Foreground: Sendable, Equatable {
        var command: String
        var pid: Int32
        var isAgent: Bool
    }

    static let shellCommands: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "tcsh", "ksh"]

    /// The agent running under `pid`, or nil when only shells are running.
    static func agentCommand(under pid: Int32, entries: [Entry]? = nil) -> String? {
        let result = foreground(under: pid, entries: entries)
        return result?.isAgent == true ? result?.command : nil
    }

    /// Walks the descendants of `pid`, preferring an agent and falling back to the deepest shell.
    static func foreground(under pid: Int32, entries: [Entry]? = nil) -> Foreground? {
        let table = entries ?? snapshot()
        guard !table.isEmpty else { return nil }

        var childrenByParent: [Int32: [Entry]] = [:]
        for entry in table {
            childrenByParent[entry.parent, default: []].append(entry)
        }

        // Breadth-first through the descendants, with a bound so a pathological tree cannot
        // stall the dictation pipeline.
        var queue = (childrenByParent[pid] ?? []).map { (entry: $0, depth: 0) }
        var deepestShell: Foreground?
        var deepestDepth = -1
        var visited = 0

        while !queue.isEmpty, visited < 500 {
            let (entry, depth) = queue.removeFirst()
            visited += 1
            let name = effectiveName(of: entry.command)
            if interestingCommands.contains(name) {
                return Foreground(command: name, pid: entry.pid, isAgent: true)
            }
            if shellCommands.contains(name), depth > deepestDepth {
                deepestDepth = depth
                deepestShell = Foreground(command: name, pid: entry.pid, isAgent: false)
            }
            queue.append(contentsOf: (childrenByParent[entry.pid] ?? []).map { ($0, depth + 1) })
        }
        return deepestShell
    }

    /// Every running process as (pid, parent, command).
    static func snapshot() -> [Entry] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        // `args=` rather than `comm=`: an npm-installed agent runs as `node .../claude`, and a
        // Python one as `python3 .../aider`, so the executable name alone finds neither.
        process.arguments = ["-axo", "pid=,ppid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.app.error("Could not list processes: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `ps -axo pid=,ppid=,comm=` output.
    static func parse(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let parent = Int32(parts[1])
            else { return nil }
            return Entry(pid: pid, parent: parent, command: String(parts[2]))
        }
    }

    /// Last path component of a command, ignoring a leading dash on login shells.
    static func basename(_ command: String) -> String {
        let trimmed = command.hasPrefix("-") ? String(command.dropFirst()) : command
        return trimmed.split(separator: "/").last.map(String.init)?.lowercased() ?? trimmed.lowercased()
    }

    /// The command a process really is, looking past an interpreter to the script it runs.
    /// `node /opt/homebrew/bin/claude` is Claude Code, not node.
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "uv"]

    static func effectiveName(of args: String) -> String {
        let words = args.split(separator: " ").map(String.init)
        guard let first = words.first else { return "" }
        let name = basename(first)
        guard interpreters.contains(name) else { return name }
        // Skip flags to find the script being run.
        for word in words.dropFirst() where !word.hasPrefix("-") {
            let candidate = basename(word)
            if !candidate.isEmpty { return candidate }
        }
        return name
    }
}
