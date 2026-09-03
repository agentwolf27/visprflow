import Foundation

/// How much the compiler is allowed to change what the user said.
///
/// The dial exists because the right amount of editing depends on where the text is going:
/// a shell command must survive untouched, a Slack message wants light cleanup, and a request
/// to a coding agent benefits from being restructured into goal, context, constraints and
/// verification. Research on rewriting spoken text is clear that over-editing is the common
/// failure, so the compiler always picks the lowest level that does the job.
enum EditLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Return exactly what was said.
    case verbatim
    /// Fillers, punctuation, casing, self-corrections. Word order preserved.
    case light
    /// Also reorder into a clear sequence, merge repeats, make spoken lists into lists.
    case medium
    /// Restructure into the destination's anatomy, using only spoken material.
    case full

    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .light: "Light"
        case .medium: "Organised"
        case .full: "Compiled"
        }
    }

    var summary: String {
        switch self {
        case .verbatim: "Exactly what you said"
        case .light: "Fillers and punctuation cleaned up"
        case .medium: "Reordered and organised"
        case .full: "Restructured as a prompt"
        }
    }

    private var order: Int {
        switch self {
        case .verbatim: 0
        case .light: 1
        case .medium: 2
        case .full: 3
        }
    }

    static func < (lhs: EditLevel, rhs: EditLevel) -> Bool {
        lhs.order < rhs.order
    }

    /// One step down, for the guardrail retry. Verbatim is the floor.
    var lowered: EditLevel {
        switch self {
        case .verbatim, .light: .verbatim
        case .medium: .light
        case .full: .medium
        }
    }

    /// Next level when the user presses Tab in the HUD, wrapping around.
    var cycled: EditLevel {
        switch self {
        case .verbatim: .light
        case .light: .medium
        case .medium: .full
        case .full: .verbatim
        }
    }
}
