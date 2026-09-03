# Visprflow

Hold `fn`, talk, release. The best possible prompt for wherever your cursor is lands in the
field. A prompt compiler for Claude Code, Cursor, claude.ai, Slack and email, running as a
native macOS menu bar app with on-device speech recognition.

The plan, the research behind it and the phase breakdown are in [docs/plan.html](docs/plan.html).

## Status

Phases 0 through 3 are built, plus most of the phase 4 and 5 polish. 177 tests pass. The app
is installed at `~/Applications/Visprflow.app`.

| Working | Not yet |
|---|---|
| Hold-to-talk, double-tap for hands-free, Escape to cancel | Streaming cloud speech recognition (phase 4) |
| On-device transcription with Parakeet v3 | Groq as a faster rewrite provider |
| Destination detection and per-destination instructions | Selected text and screen OCR as context |
| Prompt compilation with guardrails and a raw fallback | Snippets and a prompt library |
| Preview with Return to insert, Tab to change level | Notarised distribution and Sparkle updates |
| Repository vocabulary from your git workspace | |

## What you have to do first

Three permissions, granted once, in the setup window that opens on first launch:

| Grant | Used for |
|---|---|
| Microphone | Recording while the key is held. Audio never leaves the Mac. |
| Accessibility | Pasting into the focused app and watching for the trigger key. |
| Input Monitoring | Noticing `fn` in any app. |

Two more things worth doing in that window:

- **Set the fn key to "Do Nothing"** in System Settings, Keyboard. macOS handles the emoji
  picker before any app sees the key. The setup window detects this and links straight there.
  On an external keyboard, switch the trigger to Right Option instead: `fn` only reaches apps
  from the built-in keyboard.
- **Paste an Anthropic API key.** Without one the app still dictates, inserting the cleaned
  transcript; with one it compiles the transcript into a prompt shaped for the destination.

Launch from `~/Applications`, not from `build/`. Debug builds are ad-hoc signed, so macOS ties
the grants to the exact binary and every rebuild loses them.

## How it behaves

| Where your cursor is | What you get |
|---|---|
| Terminal running `claude` or `codex` | A structured prompt: goal, symptom, files you named, constraints, verification. Preview first, Return to insert. |
| Cursor, VS Code, Zed, Windsurf | The same, for the agent chat pane. |
| claude.ai, ChatGPT, Gemini, Perplexity | One clear ask with your context, inserted straight away. |
| Slack, iMessage, WhatsApp, Discord | Light cleanup that keeps your register, lowercase included. |
| Mail, Gmail, Superhuman | The ask in the first sentence, short paragraphs. |
| A shell prompt with no agent | Exactly what you said. Never capitalised, never punctuated. |
| A password field, or Terminal with Secure Keyboard Entry | Nothing is inserted. The overlay says so and the transcript goes to your clipboard. |

Hold `shift` with the trigger for verbatim, `control` for a full compile. Say "verbatim:" or
"prompt mode" to do the same with your voice.

## Requirements

- macOS 15 or later, Apple Silicon
- Xcode 16.3 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```bash
make install   # Release build into ~/Applications (do this, then launch from there)
make test      # 177 unit tests, about a minute
make verify-stt   # speech tests against audio synthesised with `say`; needs no microphone
make logs      # stream the app's own log
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and git-ignored.

## Layout

```
project.yml              XcodeGen definition
Visprflow/
  App/                   @main, app delegate, observable app state
  Core/Hotkey/           Gesture state machine, CGEventTap, secure input
  Core/Audio/            Capture, ring buffer, file loading
  Core/STT/              Transcriber protocol, Parakeet via FluidAudio
  Core/Compile/          Levels, system prompt, Claude client, guardrails
  Core/Destination/      Destination model, resolver, focus context, process tree
  Core/Context/          Workspace probe, repository vocabulary
  Core/Insert/           Paste with clipboard restore, keycode resolution
  Core/Pipeline/         DictationController, the orchestrator
  Core/Storage/          GRDB history and timings
  UI/                    Menu bar, setup window, overlay, destination settings
VisprflowTests/          XCTest target
Fixtures/golden/         Messy transcript to expected output cases
docs/plan.html           The plan
```

## Privacy

Audio never leaves the machine. The only thing sent anywhere is the transcript, the vocabulary
list, the destination name and your own instruction, and only when an edit level above verbatim
applies. Every dictation is stored locally in
`~/Library/Application Support/Visprflow/visprflow.sqlite` together with the exact request that
was sent, so the claim is inspectable rather than promised.

## Git workflow

`main` receives only `dev`. Feature branches start from the latest `dev` and return to it by
pull request after a rebase. Branches are never deleted.
