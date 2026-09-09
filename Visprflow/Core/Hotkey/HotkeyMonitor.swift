import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

/// Watches the keyboard for the trigger key and turns it into `HotkeyAction`s.
///
/// Uses an active `CGEventTap` rather than Carbon's `RegisterEventHotKey`, because Carbon cannot
/// bind a modifier-only chord such as fn. The trade-off is that the tap stops seeing key events
/// while Secure Event Input is on; modifier changes still arrive, so the trigger itself keeps
/// working there and only Escape-to-cancel is lost.
///
/// The gesture state sits behind a mutex rather than an actor because the tap callback has to
/// decide *synchronously* whether to swallow an event, and an actor hop cannot answer in time.
final class HotkeyMonitor: @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case tapCreationFailed
        var errorDescription: String? {
            "Could not watch the keyboard. Grant Accessibility and Input Monitoring, then try again."
        }
    }

    /// Called for every action the gesture machine produces. Invoked on the main thread,
    /// because the tap's run loop source is attached to the main run loop.
    private let onAction: @Sendable (HotkeyAction) -> Void

    private let gesture: Mutex<HotkeyGesture>
    private let triggerBox: Mutex<TriggerKey>
    /// True while the overlay shows a preview, so Return, Tab, Escape and R belong to us
    /// rather than to the app behind it.
    private let previewMode = Mutex(false)
    /// Set while the setup window is waiting for the user to press their chosen key.
    private let recorder = Mutex<(@Sendable (TriggerKey) -> Void)?>(nil)
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    init(
        trigger: TriggerKey = .fn,
        config: HotkeyGesture.Config = .default,
        onAction: @escaping @Sendable (HotkeyAction) -> Void
    ) {
        self.triggerBox = Mutex(trigger)
        self.gesture = Mutex(HotkeyGesture(config: config))
        self.onAction = onAction
    }

    var trigger: TriggerKey { triggerBox.withLock { $0 } }
    var isRecording: Bool { gesture.withLock { $0.isRecording } }
    var isLocked: Bool { gesture.withLock { $0.isLocked } }

    @MainActor
    func start() throws {
        Log.hotkey.info("Starting event tap for \(self.trigger.displayName, privacy: .public); trusted=\(AXIsProcessTrusted(), privacy: .public)")
        guard tap == nil else {
            Log.hotkey.info("Event tap already running")
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let reference = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: reference
        ) else {
            throw Failure.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        startWatchdog()
        Log.hotkey.info("Event tap started for \(self.trigger.displayName, privacy: .public)")
    }

    deinit {
        // The tap holds an unretained pointer to self and the run loop holds the source, so a
        // monitor that is deallocated without stop() would leave a dangling callback.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Disabling stops events; invalidating is what actually tears the port down.
            // Without it the Mach port and its send right stay alive for the life of the
            // process, and every trigger change leaks another one.
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    @MainActor
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        Log.hotkey.info("Event tap stopped")
    }

    func setTrigger(_ key: TriggerKey) {
        triggerBox.withLock { $0 = key }
        // A gesture in flight refers to the old key, so end it cleanly.
        deliver(gesture.withLock { $0.handle(.resynchronise) })
    }

    /// Routes Return, Tab, Escape and R to the overlay while a preview is on screen.
    /// The overlay is a non-activating panel and never holds focus, so the keys have to be
    /// intercepted here and swallowed before the app behind it sees them.
    func setPreviewMode(_ enabled: Bool) {
        previewMode.withLock { $0 = enabled }
    }

    /// Captures the next key the user presses and reports it, instead of matching the trigger.
    ///
    /// This exists because guessing a key from the keyboard's label does not work: compact and
    /// third-party keyboards often have no Right Option, and `fn` never leaves the built-in
    /// keyboard. Asking the hardware is the only reliable way.
    func recordNextKey(_ handler: @escaping @Sendable (TriggerKey) -> Void) {
        recorder.withLock { $0 = handler }
        Log.hotkey.info("Recording the next key press")
    }

    func cancelRecording() {
        recorder.withLock { $0 = nil }
    }

    var isRecordingKey: Bool { recorder.withLock { $0 != nil } }

    /// Reports a pressed key to a waiting recorder. Returns true when the event was consumed.
    private func captureIfRecording(type: CGEventType, event: CGEvent) -> Bool {
        guard let handler = recorder.withLock({ $0 }) else { return false }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .flagsChanged:
            // Only report on the press, not the release, so the key is captured as it goes down.
            guard let mask = TriggerKey.deviceFlag(forModifier: keyCode),
                  event.flags.rawValue & mask != 0
            else { return true }
        case .keyDown:
            // Escape means "never mind", and is not a sensible trigger anyway.
            if keyCode == CGKeyCode(kVK_Escape) {
                recorder.withLock { $0 = nil }
                Log.hotkey.info("Key recording cancelled")
                return true
            }
        default:
            return false
        }

        let key = TriggerKey.recognised(keyCode: keyCode, flags: event.flags)
        recorder.withLock { $0 = nil }
        Log.hotkey.info("Recorded trigger: \(key.displayName, privacy: .public) code=\(key.keyCode, privacy: .public) mask=\(key.flagMask, privacy: .public)")
        handler(key)
        return true
    }

    /// Ends a hands-free session because the microphone heard nothing for a while.
    func reportSilenceTimeout() {
        deliver(gesture.withLock { $0.handle(.silenceTimeout) })
    }

    /// Finishes a dictation whose trigger has been held past the safety ceiling, which in
    /// practice means the key-up was never delivered.
    func reportHoldTimeout() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        deliver(gesture.withLock { $0.handle(.holdTimeout(at: now)) })
    }

    // MARK: Tap callback

    /// Returns nil to swallow the event. Runs on the main run loop.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // While recording a new trigger, every key belongs to the recorder. Swallow it so the
        // key does not also reach whatever is behind the setup window.
        if isRecordingKey, captureIfRecording(type: type, event: event) {
            return type == .flagsChanged
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched our tap off, usually because a callback was slow. Re-enable
            // it and abandon any gesture, since the matching key-up may have been missed.
            reenableTap()
            Log.hotkey.error("Event tap was disabled by the system; re-enabled")
            deliver(gesture.withLock { $0.handle(.resynchronise) })
            return true

        case .flagsChanged:
            let trigger = self.trigger
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == trigger.keyCode else { return true }
            let isDown = trigger.isHeld(in: event.flags)
            // Monotonic: a clock step must not corrupt the press and double-tap windows.
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            let modifiers = Self.modifiers(from: event.flags)
            deliver(gesture.withLock {
                $0.handle(isDown
                    ? .triggerDown(at: now, modifiers: modifiers)
                    : .triggerUp(at: now, modifiers: modifiers))
            })
            return true

        case .keyUp:
            // Only reached for a non-modifier trigger; modifier releases arrive as flagsChanged.
            let trigger = self.trigger
            guard !trigger.isModifier,
                  CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == trigger.keyCode
            else { return true }
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            deliver(gesture.withLock {
                $0.handle(.triggerUp(at: now, modifiers: Self.modifiers(from: event.flags)))
            })
            return false

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            // A non-modifier trigger starts the gesture here. autorepeat is ignored so holding
            // the key does not restart the capture over and over.
            let trigger = self.trigger
            if !trigger.isModifier, keyCode == trigger.keyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                    deliver(gesture.withLock {
                        $0.handle(.triggerDown(at: now, modifiers: Self.modifiers(from: event.flags)))
                    })
                }
                // Swallow it: the trigger must not type into the app behind us.
                return false
            }

            if previewMode.withLock({ $0 }), let key = Self.previewKey(for: keyCode, flags: event.flags) {
                deliver(.preview(key))
                // Swallow it: the overlay owns these keys while a preview is up.
                return false
            }

            guard keyCode == CGKeyCode(kVK_Escape) else { return true }
            let action = gesture.withLock { machine -> HotkeyAction in
                machine.isRecording ? machine.handle(.escape) : .none
            }
            guard action != .none else { return true }
            deliver(action)
            // Swallow the Escape so cancelling a dictation does not also reach the app behind it.
            return false

        default:
            return true
        }
    }

    private func reenableTap() {
        // `tap` is only mutated on the main actor, and this callback runs there too.
        MainActor.assumeIsolated {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }

    private func deliver(_ action: HotkeyAction) {
        guard action != .none else { return }
        Log.hotkey.debug("Gesture produced \(String(describing: action), privacy: .public)")
        onAction(action)
    }

    /// Maps a key press to a preview action. Modified presses are left alone so shortcuts
    /// such as ⌘R in the app behind the overlay keep working.
    private static func previewKey(for keyCode: CGKeyCode, flags: CGEventFlags) -> PreviewKey? {
        let interesting: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard flags.intersection(interesting).isEmpty else { return nil }
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .insert
        case kVK_Tab: return .cycleLevel
        case kVK_Escape: return .cancel
        case kVK_ANSI_R: return .rerecord
        default: return nil
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> GestureModifiers {
        var result: GestureModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    /// The system disables a slow tap. Poll so that is noticed even when no further events
    /// arrive to carry the notification.
    @MainActor
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
                Log.hotkey.error("Event tap found disabled by the watchdog; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
                self.deliver(self.gesture.withLock { $0.handle(.resynchronise) })
            }
        }
        // Common modes. A default-mode timer is suspended while a menu is open or a window is
        // being dragged, which is precisely when a slow main thread gets the tap disabled — so
        // the default mode would put the watchdog to sleep exactly when it is needed.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}

/// Free function so the tap callback stays a plain C function pointer with no captured context.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

/// The system action bound to the fn key, which competes with using fn as a trigger.
enum FnKeyUsage: Int, Sendable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmojiPicker = 2
    case startDictation = 3

    var conflictsWithTrigger: Bool { self != .doNothing }

    var description: String {
        switch self {
        case .doNothing: "does nothing"
        case .changeInputSource: "changes the input source"
        case .showEmojiPicker: "opens the emoji picker"
        case .startDictation: "starts Apple's dictation"
        }
    }

    /// Reads the current setting. WindowServer owns this action, so an event tap cannot suppress
    /// it: the user has to set it to "Do Nothing" for a clean fn trigger.
    static var current: FnKeyUsage {
        let value = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"]
        guard let number = value as? Int else { return .showEmojiPicker }
        return FnKeyUsage(rawValue: number) ?? .showEmojiPicker
    }
}
