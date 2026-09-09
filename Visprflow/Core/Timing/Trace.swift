import Foundation

/// Pipeline stages in the order they normally occur. Every stage reports into a `Trace`
/// so latency is measured from day one rather than guessed later.
enum Stage: String, CaseIterable, Codable, Sendable {
    case keyDown
    case captureStarted
    case keyUp
    case transcriptReady
    case compileFirstToken
    case compileDone
    case previewShown
    case inserted
}

/// Timing trace for a single dictation. Offsets are measured from `start`, which the
/// hotkey engine creates on key-down. Key-up (`t0` in the plan) is itself a mark, so
/// "key-up to inserted" is `duration(from: .keyUp, to: .inserted)`.
struct Trace: Sendable {
    struct Mark: Sendable, Equatable {
        let stage: Stage
        let offset: Duration
    }

    let id: UUID
    let start: ContinuousClock.Instant
    private(set) var marks: [Mark] = []

    init(id: UUID = UUID(), clock: ContinuousClock = .continuous) {
        self.id = id
        self.start = clock.now
    }

    /// Records the stage at the current instant. Re-marking a stage replaces the earlier mark.
    mutating func mark(_ stage: Stage, clock: ContinuousClock = .continuous) {
        let offset = clock.now - start
        marks.removeAll { $0.stage == stage }
        marks.append(Mark(stage: stage, offset: offset))
        marks.sort { $0.offset < $1.offset }
    }

    func offset(of stage: Stage) -> Duration? {
        marks.first { $0.stage == stage }?.offset
    }

    /// Time between two marks, or nil if either is missing.
    func duration(from: Stage, to: Stage) -> Duration? {
        guard let a = offset(of: from), let b = offset(of: to) else { return nil }
        return b - a
    }

    /// Duration of each mark since the previous mark, for storage as `stageTiming` rows.
    func stageDurations() -> [(stage: Stage, offset: Duration, sinceLast: Duration)] {
        var previous: Duration = .zero
        return marks.map { mark in
            defer { previous = mark.offset }
            return (mark.stage, mark.offset, mark.offset - previous)
        }
    }

    /// Records a stage at an exact offset. Tests use this to assert latency budgets without
    /// sleeping; production code uses `mark(_:)`.
    mutating func mark(_ stage: Stage, offset: Duration) {
        marks.removeAll { $0.stage == stage }
        marks.append(Mark(stage: stage, offset: offset))
        marks.sort { $0.offset < $1.offset }
    }

    /// One-line summary such as `keyUp+0ms transcriptReady+84ms inserted+212ms`.
    /// Formatted with `String(format:)` rather than `.formatted`, which is locale-aware and
    /// would render `1.235ms` for 1234.5 in a German locale.
    func summary() -> String {
        marks.map { String(format: "%@+%.0fms", $0.stage.rawValue, Trace.milliseconds($0.offset)) }
            .joined(separator: " ")
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
