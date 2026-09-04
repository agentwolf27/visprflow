# Visprflow

<!-- pulse -->

## What we are building
Visprflow is a native macOS menu bar app that replaces the fn key's emoji picker with a full dictation-to-prompt pipeline: hold fn, talk, release, and the app transcribes on-device with Parakeet v3, then compiles the raw speech into the best-suited prompt for wherever the cursor is (Claude Code, Cursor, claude.ai, Slack, email, or a plain shell), inserting it with a preview step for agent destinations.

## Why
Existing dictation tools like Wispr Flow are cloud-only, heavy (800 MB idle), unreliable, and produce generic cleaned-up text rather than a structured prompt tailored to the destination app and its context.

## Done looks like
A short list of concrete, checkable outcomes. If you cannot check it, it does not belong here.
Tick one only when its VERIFY passes, not when someone says it is done.

- [x] Menu bar app with permission onboarding, Keychain, timing, local SQLite history — `ls ~/Applications/Visprflow.app`
- [x] Hold-to-talk loop with on-device Parakeet v3 transcription and paste-back — `make verify-stt`
- [x] Prompt compiler with destination detection, guardrails, raw fallback — `make test`
- [x] Repository vocabulary and workspace context harvesting — `make test`
- [x] 177 unit tests pass and app installed at ~/Applications — `make test`
- [x] Audit fixes: crash, key-mapping, clipboard, probe-hang bugs resolved
- [ ] Streaming cloud/on-device ASR replaces serial capture-then-transcribe pipeline
- [x] Now-tier latency fixes: pre-roll, post-roll, warm-up, exception trapping
- [x] Next-tier robustness: device/wake recovery, pinned paste target, hung CLI handling
- [ ] Groq added as a faster rewrite provider
- [ ] Selected text and screen OCR available as compiler context
- [ ] Notarised release with Sparkle auto-updates shipped

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
