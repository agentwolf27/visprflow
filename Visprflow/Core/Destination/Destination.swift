import Foundation

/// Where the compiled text is going, and how it should behave when it gets there.
///
/// This is the piece Wispr Flow does not have. It offers four fixed tones chosen by app
/// category; here every destination carries its own edit level, insertion mechanism, whether
/// the user sees a preview before anything is inserted, and a free-text instruction the user
/// writes themselves.
struct Destination: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var displayName: String
    /// Level used when the utterance gives no reason to choose otherwise.
    var defaultLevel: EditLevel
    var strategy: InsertionStrategy
    /// True when the compiled text waits for Return rather than being inserted immediately.
    /// Worth the keystroke where a wrong prompt costs more than a wrong message.
    var requiresPreview: Bool
    /// Whether "send it" is allowed to press Return after inserting.
    var allowsAutoSubmit: Bool
    /// The user's own instruction for this destination, appended to the compiler's rules.
    var instructions: String?

    /// Text longer than this many words is worth fully restructuring for this destination.
    var fullLevelWordThreshold: Int

    init(
        id: String,
        displayName: String,
        defaultLevel: EditLevel,
        strategy: InsertionStrategy = .paste,
        requiresPreview: Bool = false,
        allowsAutoSubmit: Bool = false,
        instructions: String? = nil,
        fullLevelWordThreshold: Int = .max
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultLevel = defaultLevel
        self.strategy = strategy
        self.requiresPreview = requiresPreview
        self.allowsAutoSubmit = allowsAutoSubmit
        self.instructions = instructions
        self.fullLevelWordThreshold = fullLevelWordThreshold
    }
}

extension Destination {
    /// A coding agent running in a terminal. The reason this app exists.
    static let claudeCode = Destination(
        id: "claude_code",
        displayName: "Claude Code",
        defaultLevel: .full,
        strategy: .paste,
        requiresPreview: true,
        allowsAutoSubmit: true,
        fullLevelWordThreshold: 25
    )

    static let cursor = Destination(
        id: "cursor",
        displayName: "Cursor",
        defaultLevel: .full,
        strategy: .paste,
        requiresPreview: true,
        allowsAutoSubmit: true,
        fullLevelWordThreshold: 25
    )

    static let codex = Destination(
        id: "codex",
        displayName: "Codex CLI",
        defaultLevel: .full,
        strategy: .paste,
        requiresPreview: true,
        allowsAutoSubmit: true,
        fullLevelWordThreshold: 25
    )

    /// A chat assistant in the browser.
    static let chat = Destination(
        id: "chat",
        displayName: "Chat",
        defaultLevel: .medium,
        strategy: .paste,
        requiresPreview: false,
        allowsAutoSubmit: false,
        fullLevelWordThreshold: 60
    )

    /// Slack, iMessage, WhatsApp, Discord. Register matters more than structure here.
    static let message = Destination(
        id: "message",
        displayName: "Message",
        defaultLevel: .light,
        strategy: .paste
    )

    static let email = Destination(
        id: "email",
        displayName: "Email",
        defaultLevel: .light,
        strategy: .paste,
        fullLevelWordThreshold: 80
    )

    /// Editors, notes, documents.
    static let document = Destination(
        id: "document",
        displayName: "Document",
        defaultLevel: .light,
        strategy: .paste
    )

    /// A shell prompt with no agent running. Commands must survive untouched.
    static let shell = Destination(
        id: "shell",
        displayName: "Shell",
        defaultLevel: .verbatim,
        strategy: .paste
    )

    static let all: [Destination] = [
        .claudeCode, .cursor, .codex, .chat, .message, .email, .document, .shell,
    ]

    static func named(_ id: String) -> Destination? {
        all.first { $0.id == id }
    }
}
