# Visprflow

<!-- pulse -->

## What we are building
Visprflow is a native macOS menu bar app that takes over the fn key (once macOS's emoji picker on that key is set to Do Nothing) for a full dictation-to-prompt pipeline: hold fn, talk, release, and the app transcribes on-device with Parakeet v3, then compiles the raw speech into the best-suited prompt for wherever the cursor is (Claude Code, Cursor, claude.ai, Slack, email, or a plain shell), inserting it with a preview step for agent destinations.

## Why
Existing dictation tools like Wispr Flow are cloud-only, heavy (800 MB idle), unreliable, and produce generic cleaned-up text rather than a structured prompt tailored to the destination app and its context.

## Done looks like
A short list of concrete, checkable outcomes. If you cannot check it, it does not belong here.
Tick one only when its VERIFY passes, not when someone says it is done.

- [x] Menu bar app with permission onboarding, Keychain, timing, local SQLite history — `ls ~/Applications/Visprflow.app`
- [x] Hold-to-talk loop with on-device Parakeet v3 transcription and paste-back — `make verify-stt`
- [x] Prompt compiler with destination detection, guardrails, raw fallback — `make test`
- [x] Repository vocabulary and workspace context harvesting — `make test`
- [x] The unit test suite passes (README cites 177; not independently counted) — `make test`
- [x] Audit fixes: crash trap, Right-Option key mapping, clipboard restore, probe hang — `test -f Visprflow/Core/Audio/ObjCException.m`
- [x] Live streaming transcript preview while speaking — `test -f Visprflow/Core/STT/StreamingTranscriber.swift`
- [-] Streamed transcript replaces the batch model — evaluated in 14f55cf and declined: accuracy wins a trade that costs 80 ms
- [x] Now-tier latency fixes: pre-roll, post-roll, warm-up, exception trapping — `grep -q postRollDuration Visprflow/Core/Audio/AudioCapture.swift`
- [x] Next-tier robustness: device/wake recovery, pinned paste target, hung CLI handling — `grep -q observeDeviceChanges Visprflow/Core/Audio/AudioCapture.swift`
- [x] Second audit sweep: overlay retain cycle, timer run-loop modes, tap port, preview lifetime — `grep -q "HUDHost(box:" Visprflow/Core/Pipeline/DictationController.swift`
- [x] The streaming model is released when idle, so its 580 MB comes back — `grep -q idleLifetime Visprflow/Core/STT/StreamingTranscriber.swift`
- [x] The speech model costs under 300 MB of our own heap, not 1.2 GB — `make verify-memory`
- [ ] The 40-item golden set exercised end to end (plan.html's phase-2 bar; 8 fixtures today) — `test "$(find Fixtures/golden -name '*.json' | wc -l)" -ge 40`

## Later

From plan.html's phases 3–5. docs/roadmap.html supersedes that plan and, with its twelve items shipped or declined, queues none of these yet.

- [ ] Groq added as a faster rewrite provider — `grep -rq GroqGenerator Visprflow/Core/Compile`
- [ ] Selected text and screen OCR available as compiler context
- [ ] Notarised release with Sparkle auto-updates shipped — `grep -q Sparkle project.yml`

## Out of scope
- Uploading raw audio to any cloud service by default (on-device transcription is the default)
- Fixed-tone generic dictation cleanup like Wispr Flow's four tones
- Cross-platform support (Windows/Linux); macOS Apple Silicon only
- Snippets and a prompt library (deferred past phase 5)

## Constraints
- macOS 15+, Apple Silicon, native Swift, XcodeGen-generated project (project.yml is source of truth)
- On-device STT via Parakeet v3 through FluidAudio; FluidAudio 0.15.6 already pinned, no dependency bump needed for streaming
- Rewrite providers limited to local, Claude subscription, or Anthropic API key
- Must build with a stable signing identity so permission grants survive rebuilds
- Debug builds must not be distributed from ~/Applications; only Release install target is used
- git workflow: main only receives dev; feature branches rebase back into dev, never deleted

---

_Drafted by Pulse on 2026-09-04 from README, git log, docs and chat history. Evidence for ticked items:_
- Menu bar app with permission onboarding, Keychain, timing, local SQLite history — README status table; commit 'feat(phase-0): foundations'
- Hold-to-talk loop with on-device Parakeet v3 transcription and paste-back — commit 'feat(phase-1): the dictation loop'
- Prompt compiler with destination detection, guardrails, raw fallback — commit 'feat(phase-2,3): prompt compiler, destinations'
- Repository vocabulary and workspace context harvesting — README: 'Repository vocabulary from your git workspace'
- 177 unit tests pass and app installed at ~/Applications — README 'Status'; build-report.html '177 unit tests passing'
- Audit fixes: crash, key-mapping, clipboard, probe-hang bugs resolved — git log: 'fix: stop the app crashing...', 'fix: bound the shell probes and cap...'
- Now-tier latency fixes: pre-roll, post-roll, warm-up, exception trapping — commit 'feat: the "now" tier — first word, last word, first run, silent failures'
- Next-tier robustness: device/wake recovery, pinned paste target, hung CLI handling — commit 'feat: the "next" tier — device changes, wrong-window pastes, a hung CLI'
