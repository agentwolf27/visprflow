# Visprflow

Hold `fn`, talk, release. The best possible prompt for wherever your cursor is lands in the
field. A prompt compiler for Claude Code, Cursor, claude.ai, Slack and email, running as a
native macOS menu bar app with on-device speech recognition.

The full build plan, research and phase breakdown is in [docs/plan.html](docs/plan.html).

## Status

Phase 0 (foundations): menu bar app, permission onboarding, Keychain secrets, per-stage
timing, local SQLite history schema, golden-set fixtures, unit tests. No dictation yet;
that is phase 1.

## Requirements

- macOS 15 or later (Apple Silicon)
- Xcode 16.3 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```bash
make gen     # generate Visprflow.xcodeproj from project.yml
make build   # Debug build into ./build
make test    # unit tests
make run     # launch the menu bar app
make logs    # stream the app's os_log output
```

Open `Visprflow.xcodeproj` in Xcode after `make gen` if you prefer the IDE. The project file
is git-ignored; `project.yml` is the source of truth.

## Permissions

The setup window (menu bar icon → Open Setup…) walks through the three grants:

| Grant | Used for |
|---|---|
| Microphone | Recording while the key is held. Audio never leaves the Mac. |
| Accessibility | Pasting into the focused app and reading the selected text. |
| Input Monitoring | Noticing the `fn` key in any app. |

Screen Recording and Apple Events are requested later, only when the features that need them
are switched on.

### Keeping the Accessibility grant across rebuilds

Debug builds are ad-hoc signed. macOS ties the Accessibility grant to the code signature, so a
rebuild can make the grant disappear. To make it stick during development:

1. Keychain Access → Certificate Assistant → Create a Certificate…
   Name `Visprflow Dev`, type **Code Signing**, self-signed.
2. In `project.yml`, set `CODE_SIGN_IDENTITY: "Visprflow Dev"` under `settings.base`.
3. `make gen && make build`, then grant Accessibility once.

## Layout

```
project.yml            XcodeGen definition (targets, packages, Info.plist, entitlements)
Visprflow/
  App/                 @main, app delegate, observable app state
  Core/Logging         os_log categories per pipeline area
  Core/Timing          Trace: per-stage marks for every dictation
  Core/Secrets         Keychain wrapper for API keys
  Core/Permissions     Microphone, Accessibility, Input Monitoring status and prompts
  Core/Paste           PasteProbe: phase 0 smoke test, replaced by Inserter in phase 1
  Core/Storage         GRDB database, migrations, record types
  Core/Golden          Golden-case model and mechanical output checks
  UI/                  Menu bar content, setup window
VisprflowTests/        XCTest target (hosted by the app)
Fixtures/golden/       Messy transcript → expected output cases
docs/plan.html         The plan
```

## Git workflow

`main` receives only `dev`. Feature branches start from the latest `dev` and return to it by
pull request after a rebase. Branches are never deleted.
