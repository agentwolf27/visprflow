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

    /// The most relevant descendant command of `pid`, or nil when only shells are running.
    static func agentCommand(under pid: Int32, entries: [Entry]? = nil) -> String? {
        let table = entries ?? snapshot()
        guard !table.isEmpty else { return nil }

        var childrenByParent: [Int32: [Entry]] = [:]
        for entry in table {
            childrenByParent[entry.parent, default: []].append(entry)
        }

        // Breadth-first through the descendants, with a bound so a pathological tree
        // cannot stall the dictation pipeline.
        var queue = childrenByParent[pid] ?? []
        var visited = 0
        while !queue.isEmpty, visited < 500 {
            let entry = queue.removeFirst()
            visited += 1
            let name = basename(entry.command)
            if interestingCommands.contains(name) {
                return name
            }
            queue.append(contentsOf: childrenByParent[entry.pid] ?? [])
        }
        return nil
    }

    /// Every running process as (pid, parent, command).
    static func snapshot() -> [Entry] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
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
}
