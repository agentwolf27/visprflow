import Foundation

/// How the trigger key behaves.
enum HotkeyMode: String, Codable, Sendable, CaseIterable {
    /// Hold to talk, release to compile. A double-tap locks hands-free.
    case hybrid
    /// Hold to talk only; a double-tap does nothing special.
    case pushToTalk
    /// Every press toggles recording on or off.
    case toggle
}

/// Modifiers held alongside the trigger key, read at the moment the gesture ends.
struct GestureModifiers: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let shift = GestureModifiers(rawValue: 1 << 0)
    static let control = GestureModifiers(rawValue: 1 << 1)
    static let option = GestureModifiers(rawValue: 1 << 2)
    static let command = GestureModifiers(rawValue: 1 << 3)
    static let none: GestureModifiers = []
}

/// Input events, deliberately free of AppKit so the machine can be driven by a fake clock.
enum HotkeyEvent: Equatable, Sendable {
    case triggerDown(at: TimeInterval, modifiers: GestureModifiers)
    case triggerUp(at: TimeInterval, modifiers: GestureModifiers)
    case escape
    /// Silence ran long enough to end a hands-free session.
    case silenceTimeout
    /// The trigger has been held past the safety ceiling; finish what was captured.
    case holdTimeout(at: TimeInterval)
    /// The event tap was disabled and re-enabled; any in-flight gesture is unreliable.
    case resynchronise
}

/// Keys the overlay responds to while a compiled prompt is waiting for approval.
enum PreviewKey: String, Equatable, Sendable {
    case insert      // Return
    case cycleLevel  // Tab
    case cancel      // Escape
    case rerecord    // R
}

/// What the pipeline should do next.
enum HotkeyAction: Equatable, Sendable {
    case none
    /// Begin capturing audio. Capture always starts on key-down so no speech is lost.
    case startCapture
    /// Stop capturing and compile what was captured.
    case finishCapture(modifiers: GestureModifiers, locked: Bool)
    /// Stop capturing and throw the audio away.
    case discardCapture(reason: DiscardReason)
    /// Recording continues with the key released.
    case lockedOn
    /// A key pressed while the overlay is showing a preview.
    case preview(PreviewKey)
}

enum DiscardReason: String, Equatable, Sendable {
    case tooShort
    case escape
    case resynchronise
    /// The key was held past the safety ceiling, so the key-up was probably never delivered.
    case tooLong
}

/// Push-to-talk with double-tap-to-lock for the trigger key.
///
/// Rules, matching the plan:
/// - Capture starts on key-down, so the first word is never clipped.
/// - A press shorter than `minimumPress` is an accidental tap and its audio is discarded.
/// - Two short taps inside `doubleTapWindow` lock hands-free recording; the next press,
///   or a silence timeout, ends it.
/// - Escape cancels from any recording state. A mouse click does not.
struct HotkeyGesture: Sendable {
    struct Config: Sendable, Equatable {
        var mode: HotkeyMode = .hybrid
        /// Presses shorter than this are treated as accidental taps.
        var minimumPress: TimeInterval = 0.3
        /// Two taps closer together than this lock hands-free mode.
        var doubleTapWindow: TimeInterval = 0.4
        static let `default` = Config()
    }

    enum State: Equatable, Sendable {
        /// Not recording.
        case idle
        /// Key held, capturing. Releasing compiles (or discards if too short).
        case holding(since: TimeInterval)
        /// Second tap of a double-tap is held; releasing it starts hands-free.
        case lockArming
        /// Capturing hands-free with the key released.
        case locked
        /// Key held again during hands-free; releasing it compiles.
        case lockStopping
    }

    let config: Config
    private(set) var state: State = .idle
    /// End time of the last press too short to count, for double-tap detection.
    private var lastShortTapEnded: TimeInterval?

    init(config: Config = .default) {
        self.config = config
    }

    var isRecording: Bool {
        state != .idle
    }

    var isLocked: Bool {
        switch state {
        case .locked, .lockStopping, .lockArming: true
        case .idle, .holding: false
        }
    }

    mutating func handle(_ event: HotkeyEvent) -> HotkeyAction {
        switch event {
        case let .triggerDown(at, _):
            handleDown(at: at)
        case let .triggerUp(at, modifiers):
            handleUp(at: at, modifiers: modifiers)
        case .escape:
            cancel(reason: .escape)
        case .silenceTimeout:
            handleSilence()
        case let .holdTimeout(at):
            handleHoldTimeout(at: at)
        case .resynchronise:
            cancel(reason: .resynchronise)
        }
    }

    // MARK: Private

    /// The trigger has been held past the ceiling, which in practice means the key-up was never
    /// delivered. Finish with what was captured rather than discarding it: the user did speak,
    /// and throwing away five minutes of audio to punish a missed event helps nobody.
    private mutating func handleHoldTimeout(at _: TimeInterval) -> HotkeyAction {
        switch state {
        case .idle, .lockArming:
            return .none
        case .holding:
            state = .idle
            lastShortTapEnded = nil
            return .finishCapture(modifiers: .none, locked: false)
        case .locked, .lockStopping:
            state = .idle
            lastShortTapEnded = nil
            return .finishCapture(modifiers: .none, locked: true)
        }
    }

    private mutating func handleDown(at time: TimeInterval) -> HotkeyAction {
        switch state {
        case .idle:
            if config.mode == .toggle {
                state = .lockArming
                return .startCapture
            }
            if config.mode == .hybrid,
               let previous = lastShortTapEnded,
               time - previous <= config.doubleTapWindow {
                lastShortTapEnded = nil
                state = .lockArming
                return .startCapture
            }
            state = .holding(since: time)
            return .startCapture

        case .locked:
            // Pressing again while hands-free ends the session on release.
            state = .lockStopping
            return .none

        case .holding, .lockArming, .lockStopping:
            // Auto-repeat, or a key-down we already accounted for.
            return .none
        }
    }

    private mutating func handleUp(at time: TimeInterval, modifiers: GestureModifiers) -> HotkeyAction {
        switch state {
        case .idle, .locked:
            // A key-up with no matching key-down. Nothing to do.
            return .none

        case let .holding(since):
            state = .idle
            let held = time - since
            if held < config.minimumPress {
                lastShortTapEnded = time
                return .discardCapture(reason: .tooShort)
            }
            lastShortTapEnded = nil
            return .finishCapture(modifiers: modifiers, locked: false)

        case .lockArming:
            state = .locked
            return .lockedOn

        case .lockStopping:
            state = .idle
            lastShortTapEnded = nil
            return .finishCapture(modifiers: modifiers, locked: true)
        }
    }

    private mutating func handleSilence() -> HotkeyAction {
        guard state == .locked else { return .none }
        state = .idle
        return .finishCapture(modifiers: .none, locked: true)
    }

    private mutating func cancel(reason: DiscardReason) -> HotkeyAction {
        guard isRecording else { return .none }
        state = .idle
        lastShortTapEnded = nil
        return .discardCapture(reason: reason)
    }
}
