import Foundation

/// Which model compiles a transcript, and the request shape that model needs.
///
/// Tiered rather than one model everywhere: cleanup is a fast non-reasoning job, restructuring
/// benefits from a stronger model, and published work on rewriting speech shows reasoning models
/// over-delete on literal cleanup. So thinking stays off and effort stays low throughout.
enum ModelChoice: String, Codable, Sendable, CaseIterable {
    /// Cleanup and light organising. Fast first token, cheap.
    case haiku
    /// Full restructuring into a destination's anatomy.
    case sonnet
    /// Opt-in for the hardest prompts.
    case opus

    var identifier: String {
        switch self {
        case .haiku: "claude-haiku-4-5"
        case .sonnet: "claude-sonnet-5"
        case .opus: "claude-opus-5"
        }
    }

    var displayName: String {
        switch self {
        case .haiku: "Haiku 4.5"
        case .sonnet: "Sonnet 5"
        case .opus: "Opus 5"
        }
    }

    /// `output_config.effort` is rejected by Haiku 4.5 and accepted by the Claude 5 family.
    var supportsEffort: Bool {
        switch self {
        case .haiku: false
        case .sonnet, .opus: true
        }
    }

    /// Whether an explicit `thinking: {"type": "disabled"}` is valid for this model.
    /// Haiku 4.5 simply omits the field; Opus 5 runs adaptive thinking by default and has to
    /// be told to stop, which matters because thinking would slow a sub-second rewrite.
    var acceptsDisabledThinking: Bool {
        switch self {
        case .haiku: false
        case .sonnet, .opus: true
        }
    }

    /// Which model should handle a given edit level.
    static func forLevel(_ level: EditLevel) -> ModelChoice {
        switch level {
        case .verbatim, .light, .medium: .haiku
        case .full: .sonnet
        }
    }
}
