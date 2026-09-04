import AppKit
import Observation
import SwiftUI

/// Drives one dictation from key-down to inserted text, and owns the overlay's state.
///
/// The order here is what the latency budget depends on: the focused window is sampled on
/// key-down while the user's app still owns focus, capture starts immediately, the transcript
/// is produced the moment the key comes up, and the compiled text streams into the overlay
/// while its tail is still being generated.
@MainActor
@Observable
final class DictationController {
    private(set) var hud: HUDState = .hidden
    private(set) var lastError: String?
    /// Progress while the speech model downloads, for the setup window.
    private(set) var modelProgress: Double?

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored private let compiler: any PromptCompiling
    @ObservationIgnored private let inserter: Inserter
    @ObservationIgnored private let monitor: HotkeyMonitor
    @ObservationIgnored private let settings: DestinationSettings
    @ObservationIgnored private var panel: HUDPanel?

    @ObservationIgnored private var trace = Trace()
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var activeWork: Task<Void, Never>?
    @ObservationIgnored private var previewTimeout: Task<Void, Never>?
    @ObservationIgnored private var contextTask: Task<FocusContext, Never>?
    @ObservationIgnored private var capturedContext = FocusContext.unknown
    @ObservationIgnored private let vocabulary = VocabularyCache()
    /// The dictation waiting for the user to press Return.
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        var transcript: Transcript
        var compiled: CompiledPrompt
        var destination: Destination
        /// The app this text was compiled for, so it is never pasted somewhere else.
        var bundleIdentifier: String?
    }

    /// How long hands-free recording tolerates silence before stopping on its own.
    private let silenceStopAfter: TimeInterval = 1.2

    /// A hold longer than this finishes the dictation by itself.
    ///
    /// A key-up can genuinely go missing: Secure Event Input suppresses key events entirely, so
    /// releasing a non-modifier trigger while a password field has focus is never seen. Without
    /// a ceiling the gesture stays held forever, audio accumulates at roughly 64 MB an hour, and
    /// Escape cannot rescue it because Escape is suppressed too. Five minutes is well past any
    /// real dictation.
    private let maximumHold: TimeInterval = 300

    init(
        transcriber: any Transcriber = ParakeetTranscriber(),
        compiler: any PromptCompiling = Compiler(policy: ProviderSettings().policy()),
        inserter: Inserter = Inserter(),
        settings: DestinationSettings = DestinationSettings(),
        trigger: TriggerKey = .fn
    ) {
        self.transcriber = transcriber
        self.compiler = compiler
        self.inserter = inserter
        self.settings = settings

        // The monitor needs a callback at construction, but that callback needs the controller.
        // A box breaks the cycle without leaving either side optional for the rest of its life.
        let box = ControllerBox()
        self.monitor = HotkeyMonitor(trigger: trigger) { action in
            // The tap's run loop source is on the main run loop, so this already runs on the
            // main thread. Asserting that preserves event order, which a Task hop would not.
            MainActor.assumeIsolated {
                box.controller?.handle(action)
            }
        }
        box.controller = self
    }

    // MARK: Lifecycle

    func start() throws {
        Log.app.info("DictationController.start: preparing audio")
        capture.prepare()
        Log.app.info("DictationController.start: audio prepared, starting monitor")
        try monitor.start()
    }

    func stop() {
        monitor.stop()
        capture.shutdown()
        meterTimer?.invalidate()
        panel?.dismiss()
    }

    /// Captures the next key press and reports it, for the setup window's key recorder.
    func recordNextKey(_ handler: @escaping @Sendable (TriggerKey) -> Void) {
        monitor.recordNextKey(handler)
    }

    func cancelKeyRecording() {
        monitor.cancelRecording()
    }

    func setTrigger(_ key: TriggerKey) {
        monitor.setTrigger(key)
    }

    /// Downloads and loads the speech model, reporting progress for the setup window.
    func warmUp() async {
        do {
            try await transcriber.prepare { [weak self] fraction in
                Task { @MainActor in self?.modelProgress = fraction }
            }
            modelProgress = nil
            Log.stt.info("Speech model ready")
        } catch {
            modelProgress = nil
            lastError = error.localizedDescription
            Log.stt.error("Speech model failed to prepare: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Gesture handling

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .none:
            break

        case .startCapture:
            beginCapture()

        case .lockedOn:
            show(.listening(level: capture.currentLevel, seconds: elapsed, locked: true))

        case let .finishCapture(modifiers, _):
            trace.mark(.keyUp)
            let samples = capture.stop()
            stopMeter()
            finish(samples: samples, modifiers: modifiers)

        case let .discardCapture(reason):
            capture.discard()
            stopMeter()
            clearPending()
            switch reason {
            case .tooShort:
                hide(after: 0)
            case .escape, .resynchronise:
                show(.failed(message: "Cancelled"))
                hide(after: 0.8)
            case .tooLong:
                show(.failed(message: "Stopped after \(Int(maximumHold / 60)) minutes"))
                hide(after: 2.5)
            }
            Log.app.info("Dictation discarded: \(reason.rawValue, privacy: .public)")

        case let .preview(key):
            handlePreview(key)
        }
    }

    private func beginCapture() {
        dismissTask?.cancel()
        // Starting a new dictation abandons the previous one. Without this the old one runs
        // to completion and inserts its text while this one is still recording.
        activeWork?.cancel()
        activeWork = nil
        clearPending()
        trace = Trace()
        trace.mark(.keyDown)
        startedAt = Date()
        lastError = nil
        // Only the cheap half here: this runs inside the event-tap callback, and a slow
        // callback makes macOS disable the tap, which loses the key-up and the dictation.
        let frontmost = FocusContextProvider.frontmost()
        capturedContext = frontmost
        // The expensive half (ps, lsof, git, AppleScript) runs while the user is still
        // speaking and is joined only when the transcript is ready.
        contextTask?.cancel()
        contextTask = Task.detached(priority: .userInitiated) {
            FocusContextProvider.enrich(frontmost)
        }

        do {
            try capture.start()
            trace.mark(.captureStarted)
            show(.listening(level: 0, seconds: 0, locked: false))
            startMeter()
        } catch {
            lastError = error.localizedDescription
            show(.failed(message: error.localizedDescription))
            hide(after: 2.5)
            Log.audio.error("Capture failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish(samples: [Float], modifiers: GestureModifiers) {
        guard !samples.isEmpty else {
            hide(after: 0)
            return
        }
        show(.transcribing)

        activeWork?.cancel()
        activeWork = Task { [weak self] in
            guard let self else { return }
            await self.run(samples: samples, modifiers: modifiers)
        }
    }

    private func run(samples: [Float], modifiers: GestureModifiers) async {
        do {
            // Transcription and the context probe overlap; both are needed before compiling.
            let transcript = try await transcriber.transcribe(samples: samples, hints: .none)
            trace.mark(.transcriptReady)
            let context = await contextTask?.value ?? capturedContext
            let destination = settings.apply(to: DestinationResolver.resolve(context))

            guard !transcript.isEmpty else {
                show(.failed(message: "Nothing was said"))
                hide(after: 1.5)
                return
            }

            let compiled = try await compile(
                transcript: transcript.text,
                destination: destination,
                context: context,
                modifiers: modifiers
            )
            trace.mark(.compileDone)

            if destination.requiresPreview {
                pending = Pending(
                    transcript: transcript,
                    compiled: compiled,
                    destination: destination,
                    bundleIdentifier: context.bundleIdentifier
                )
                monitor.setPreviewMode(true)
                startPreviewTimeout()
                trace.mark(.previewShown)
                show(.ready(text: compiled.text, level: compiled.level, destination: destination.displayName))
                Log.timing.info("Preview ready: \(self.trace.summary(), privacy: .public)")
            } else {
                try await insert(compiled, transcript: transcript, destination: destination)
            }

        } catch where Self.isCancellation(error) {
            // Superseded by a newer dictation, which now owns the overlay. Touching it here
            // would hide the overlay of the recording that is still in progress.
        } catch {
            report(error)
        }
    }

    /// Runs the compiler, streaming partial text into the overlay as it arrives.
    private func compile(
        transcript: String,
        destination: Destination,
        context: FocusContext,
        modifiers: GestureModifiers
    ) async throws -> CompiledPrompt {
        // Shift with the trigger means "insert exactly what I said"; Control forces a full
        // compile even for a short utterance.
        let override: EditLevel? = modifiers.contains(.shift) ? .verbatim
            : modifiers.contains(.control) ? .full
            : nil
        let decision = LevelHeuristic.decide(
            transcript: transcript,
            destination: destination,
            override: override
        )
        Log.compile.info("Level \(decision.level.rawValue, privacy: .public) for \(destination.id, privacy: .public): \(decision.reason, privacy: .public)")

        guard decision.level != .verbatim else {
            return CompiledPrompt(text: decision.transcript, level: .verbatim)
        }

        show(.compiling(partial: ""))
        return try await runCompiler(
            transcript: decision.transcript,
            level: decision.level,
            destination: destination,
            workspace: context.workspace
        )
    }

    /// One compiler call with its deltas wired to the overlay.
    private func runCompiler(
        transcript: String,
        level: EditLevel,
        destination: Destination,
        workspace: WorkspaceContext
    ) async throws -> CompiledPrompt {
        // The project's own words, so "aut midway" can come back as "auth middleware".
        // Spelling authority only: the compiler is told never to introduce a term from here
        // that the speaker did not say.
        let terms = vocabulary.terms(for: workspace)
        return try await compiler.compile(
            CompileRequest(
                transcript: transcript,
                level: level,
                destination: destination.id,
                instructions: destination.instructions,
                vocabulary: terms
            )
        ) { [weak self] partial in
            Task { @MainActor in
                guard let self, case .compiling = self.hud else { return }
                self.hud = .compiling(partial: partial)
                if self.trace.offset(of: .compileFirstToken) == nil {
                    self.trace.mark(.compileFirstToken)
                }
            }
        }
    }

    private func insert(
        _ compiled: CompiledPrompt,
        transcript: Transcript,
        destination: Destination
    ) async throws {
        try await inserter.insert(compiled.text, strategy: destination.strategy)
        trace.mark(.inserted)
        show(.inserted(characters: compiled.text.count))
        hide(after: 1.0)
        record(transcript: transcript, compiled: compiled, destination: destination, status: .inserted)
        Log.timing.info("Dictation timings: \(self.trace.summary(), privacy: .public)")
    }

    // MARK: Preview keys

    private func handlePreview(_ key: PreviewKey) {
        guard let pending else {
            monitor.setPreviewMode(false)
            return
        }
        switch key {
        case .insert:
            clearPending()
            // The compiled text was shaped for a particular app. If focus moved while the
            // preview was up, inserting it now would paste a prompt into the wrong window.
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard front == nil || pending.bundleIdentifier == nil || front == pending.bundleIdentifier else {
                Log.insert.info("Focus moved while the preview was up; not inserting")
                show(.failed(message: "Focus moved, so nothing was inserted"))
                hide(after: 2.0)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.insert(
                        pending.compiled,
                        transcript: pending.transcript,
                        destination: pending.destination
                    )
                } catch {
                    self.report(error)
                }
            }

        case .cycleLevel:
            recompile(pending, at: pending.compiled.level.cycled)

        case .cancel:
            clearPending()
            record(
                transcript: pending.transcript,
                compiled: pending.compiled,
                destination: pending.destination,
                status: .cancelled
            )
            show(.failed(message: "Cancelled"))
            hide(after: 0.6)

        case .rerecord:
            clearPending()
            hide(after: 0)
        }
    }

    /// Recompiles the same transcript at a different level, so a wrong guess costs one key
    /// rather than another recording.
    private func recompile(_ pending: Pending, at level: EditLevel) {
        show(.compiling(partial: ""))
        activeWork?.cancel()
        activeWork = Task { [weak self] in
            guard let self else { return }
            do {
                let compiled: CompiledPrompt
                if level == .verbatim {
                    compiled = CompiledPrompt(text: pending.transcript.text, level: .verbatim)
                } else {
                    compiled = try await self.runCompiler(
                        transcript: pending.transcript.text,
                        level: level,
                        destination: pending.destination,
                        workspace: self.capturedContext.workspace
                    )
                }
                var updated = pending
                updated.compiled = compiled
                self.pending = updated
                self.show(.ready(
                    text: compiled.text,
                    level: compiled.level,
                    destination: pending.destination.displayName
                ))
            } catch where Self.isCancellation(error) {
                // Superseded by another key press.
            } catch {
                self.report(error)
            }
        }
    }

    private func clearPending() {
        pending = nil
        previewTimeout?.cancel()
        previewTimeout = nil
        monitor.setPreviewMode(false)
    }

    /// A preview that is never answered releases itself, so the preview keys cannot be held
    /// hostage by a window the user walked away from.
    private func startPreviewTimeout() {
        previewTimeout?.cancel()
        previewTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.previewLifetime))
            guard !Task.isCancelled, let self, self.pending != nil else { return }
            Log.app.info("Preview expired without an answer; releasing the preview keys")
            self.clearPending()
            self.show(.failed(message: "Preview expired"))
            self.hide(after: 1.0)
        }
    }

    /// How long a compiled prompt waits for Return before releasing the keyboard.
    private static let previewLifetime: TimeInterval = 90

    // MARK: Errors and history

    /// Cancellation reaches here in two shapes: Swift's own `CancellationError`, and
    /// `GenerationError.cancelled`, which `Compiler` and `ClaudeCLIGenerator` throw in its place.
    /// Treating the second as a real failure is what let an abandoned dictation clear the
    /// overlay belonging to the dictation that replaced it, and dismiss it 2.5 s later.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case GenerationError.cancelled = error { return true }
        return false
    }

    private func report(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        // Critical: an error while a preview is up must release the preview keys. Leaving
        // them captured swallows Return, Tab, Escape and R across every app, with no visible
        // overlay explaining why, and the user's natural recovery (pressing Return) would
        // paste stale text into whatever is focused now.
        clearPending()
        show(.failed(message: message))
        // Secure input leaves the transcript on the clipboard, so that message needs longer.
        hide(after: error is InsertionError ? 3.5 : 2.5)
        Log.app.error("Dictation failed: \(message, privacy: .public)")
    }

    private func record(
        transcript: Transcript,
        compiled: CompiledPrompt,
        destination: Destination,
        status: DictationRecord.Status
    ) {
        guard let queue = Database.queue else { return }
        let record = DictationRecord(
            id: trace.id.uuidString,
            createdAt: Date(),
            destination: destination.id,
            level: compiled.level.rawValue,
            rawTranscript: transcript.text,
            compiledText: compiled.text,
            requestJSON: compiled.requestJSON,
            status: compiled.usedRawFallback ? .rawFallback : status
        )
        let timings = StageTimingRecord.rows(for: trace, dictationId: record.id)
        Task.detached {
            do {
                try await queue.write { db in
                    try record.insert(db)
                    for var row in timings { try row.insert(db) }
                }
            } catch {
                Log.db.error("Could not save dictation: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Overlay

    private var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func show(_ state: HUDState) {
        hud = state
        if panel == nil {
            panel = HUDPanel { [weak self] in
                HUDHost(controller: self)
            }
        }
        panel?.present()
    }

    /// Hides the overlay. Always releases the preview keys first: an invisible overlay must
    /// never still be capturing Return, Tab, Escape and R.
    private func hide(after delay: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.clearPending()
            self.hud = .hidden
            self.panel?.dismiss()
        }
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let locked = self.monitor.isLocked
                self.hud = .listening(level: self.capture.currentLevel, seconds: self.elapsed, locked: locked)
                // Hands-free stops itself once the room goes quiet.
                if locked, self.capture.silenceSeconds >= self.silenceStopAfter {
                    self.monitor.reportSilenceTimeout()
                }
                // A key-up that never arrives would otherwise record forever. Escape cannot
                // rescue that under Secure Input, where key events are suppressed, so the
                // ceiling is the only way out.
                if self.elapsed >= self.maximumHold {
                    Log.hotkey.error("Trigger held past \(self.maximumHold, privacy: .public)s; finishing")
                    self.monitor.reportHoldTimeout()
                }
            }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}

/// Weak holder that lets the hotkey callback reach the controller owning the monitor.
private final class ControllerBox: @unchecked Sendable {
    weak var controller: DictationController?
}

/// Bridges the observable controller into the panel's SwiftUI content.
private struct HUDHost: View {
    let controller: DictationController?

    var body: some View {
        HUDView(state: controller?.hud ?? .hidden)
    }
}
