import Foundation

/// The words a project uses, harvested so the rewriter spells them the way the code does.
///
/// Speech recognition reliably mangles technical vocabulary: in this project's own tests
/// "auth middleware" came back as "aut midway". Handing the compiler the repository's real
/// identifiers gives it what it needs to put those back, without ever letting it invent a name
/// the speaker did not say.
enum RepoVocabulary {
    /// Upper bound on terms sent with a request. The plan caps this at 300.
    static let limit = 300

    /// Identifiers worth sending: long enough to be distinctive, not a language keyword.
    static let stopWords: Set<String> = [
        "func", "class", "struct", "enum", "public", "private", "static", "return", "import",
        "let", "var", "const", "function", "export", "default", "async", "await", "throws",
        "self", "this", "true", "false", "null", "nil", "void", "string", "number", "boolean",
        "index", "value", "result", "error", "data", "text", "name", "type", "case", "guard",
        "else", "for", "while", "with", "from", "into", "the", "and", "not", "typealias",
        "protocol", "extension", "override", "final", "init", "deinit", "where", "some", "any",
    ]

    /// Builds the vocabulary for a workspace: file names plus identifiers from changed files.
    static func harvest(_ context: WorkspaceContext) -> [String] {
        guard let directory = context.directory else { return [] }

        var scored: [String: Int] = [:]

        // File base names, which are what people say out loud ("check auth middleware").
        for path in trackedFiles(in: directory).prefix(2_000) {
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            add(stem, to: &scored, weight: 2)
        }

        // Identifiers from files the user has actually been editing carry the most weight.
        for path in context.changedFiles.prefix(30) {
            let url = directory.appending(path: path)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for identifier in identifiers(in: String(contents.prefix(120_000))) {
                add(identifier, to: &scored, weight: 3)
            }
        }

        return scored
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }

    /// Files git knows about, which excludes build output and dependencies for free.
    static func trackedFiles(in directory: URL) -> [String] {
        WorkspaceProbe.git(["ls-files"], in: directory)
            .split(separator: "\n")
            .map(String.init)
    }

    /// Identifier-shaped words in a source file: camelCase, PascalCase and snake_case.
    static func identifiers(in source: String) -> [String] {
        var found: [String] = []
        var current = ""

        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                if isInteresting(current) { found.append(current) }
                current = ""
            }
        }
        if isInteresting(current) { found.append(current) }
        return found
    }

    private static func isInteresting(_ token: String) -> Bool {
        guard token.count >= 4, token.count <= 40 else { return false }
        guard token.first?.isLetter == true else { return false }
        guard !stopWords.contains(token.lowercased()) else { return false }
        // Compound shape is what makes a term worth teaching: camelCase, PascalCase or snake_case.
        if token.contains("_") { return true }
        let characters = Array(token)
        for index in 1..<characters.count where characters[index].isUppercase {
            return true
        }
        // A plain lowercase word is only interesting if it is not an ordinary English word,
        // which we approximate by requiring some length.
        return token.count >= 8
    }

    private static func add(_ token: String, to scored: inout [String: Int], weight: Int) {
        guard isInteresting(token) else { return }
        scored[token, default: 0] += weight
    }
}

/// Caches vocabulary per repository so the harvest stays off the dictation path.
@MainActor
final class VocabularyCache {
    private struct Entry {
        var branch: String?
        var terms: [String]
        var harvestedAt: Date
    }

    /// How long a harvest stays fresh when the branch has not changed.
    private let lifetime: TimeInterval = 300
    private var entries: [String: Entry] = [:]

    private func store(_ terms: [String], branch: String?, key: String) {
        entries[key] = Entry(branch: branch, terms: terms, harvestedAt: Date())
        Log.app.info("Vocabulary for \(key, privacy: .public): \(terms.count) terms")
    }

    /// Terms for a workspace, harvesting in the background when the cache is cold or stale.
    func terms(for context: WorkspaceContext) -> [String] {
        guard let directory = context.directory else { return [] }
        let key = directory.path

        if let entry = entries[key],
           entry.branch == context.gitBranch,
           Date().timeIntervalSince(entry.harvestedAt) < lifetime {
            return entry.terms
        }

        // Return whatever is cached now and refresh for next time, so a cold cache costs a
        // slightly worse first dictation rather than a slower one.
        let stale = entries[key]?.terms ?? []
        Task.detached(priority: .utility) {
            let harvested = RepoVocabulary.harvest(context)
            await MainActor.run { [weak self] in
                self?.store(harvested, branch: context.gitBranch, key: key)
            }
        }
        return stale
    }
}
