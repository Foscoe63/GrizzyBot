# GrizzyBot

Native macOS app for a team of always-on AI agents — bots you chat with, each with its own thread, computer, routines, memory, and tools. Connect a cloud or local model and every bot (current and new) runs a real tool-calling agent loop. Without a model, a scripted fallback still drives the UI offline.

UI and settings mirror the sibling `rakazo` project. Branding is **GrizzyBot**.

## Requirements

- macOS 15+
- Xcode 16+ / Swift 6

## Build

Swift Package Manager:

```bash
swift build
```

Xcode project (generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
open GrizzyBot.xcodeproj
# regenerate after editing project.yml:
xcodegen generate
```

Or from the CLI:

```bash
xcodebuild -project GrizzyBot.xcodeproj -scheme GrizzyBot -destination 'platform=macOS' build
```

## Test

```bash
swift test
```

## Run

Release app bundle (recommended):

```bash
chmod +x Scripts/make-app.sh
./Scripts/make-app.sh
```

Or run the debug binary:

```bash
swift run GrizzyBot
```

## Features

- **Welcome / auth / onboarding** — sign up, connect a model (or skip), create your first bot, answer setup questions
- **Local / LAN models** — Ollama, LM Studio, vMLX, oMLX with configurable base URL, LAN discovery, and live model fetch
- **Sidebar of bots** — search, status, previews, plugins entry, weekly usage, model settings, log out
- **Chat** — markdown bubbles, cards, asks, subagents, child bots, routines meta, working… pulse, stop, search (⌘F), edit/regenerate/branch, undo send
- **Agents** — connected models with tools (files + diffs, shell with pre-run approval, web, memory search, spawn/delete bot, MCP). Live tool cards and token/step usage. Per-bot model and tool restrictions.
- **Composer** — attach / drop files into the bot home, on-device dictation, speak replies (ElevenLabs when a key is set, otherwise macOS TTS) and a finish notification. Warns before sending a vault-sized paste.
- **Skills** — holaOS-style SKILL.md catalog (research, browser, office docs, coding, memory). Matching skills are inlined; others load with `read_skill`.
- **Shared memory** — workspace MEMORY with `search_memory` retrieval; `remember` writes bot-local or shared
- **Templates** — Researcher, Writer, Coder, Operator, Coworker presets when creating a bot
- **Composer** — attach / drop files into the bot home, on-device dictation, speak replies (macOS TTS) and a finish notification
- **Computer panel** — persistent in-app browser (cookies survive relaunch), This Mac via Accessibility, boot overlay, take control / release
- **Routines** — schedule picker, run now, background ticker + menu bar extra, optional launch at login
- **Plugins** — Composio Connect for browser OAuth; search/list/get as well as write. Paste an API token if you have no Connect key.
- **Settings** — edit, per-bot model, export JSON, iCloud Drive / Documents backup, delete (child bots remain)
- **Diagnostics** — copy last run log and crash dump; optional Sentry DSN
- **Updates** — Sparkle Check for Updates (Debug and Release). Signed DMG items are added to `appcast.xml` by `Scripts/publish-update.sh`
- **Backup** — iCloud container when the app is team-signed; otherwise iCloud Drive or Documents
- **Local persistence** — `~/Library/Application Support/GrizzyBot/`

## Architecture

| Target | Role |
|---|---|
| `GrizzyBotCore` | Domain models, cron, model catalog, LLM agent loop, scripted fallback, persistence, `AppStore` |
| `GrizzyBot` | SwiftUI app |
| `GrizzyBotCoreTests` | Cron, agent loop, ScriptedRuntime, Store suites |
| `GrizzyBotAppTests` | SwiftUI overlay snapshots (Xcode) |
| `GrizzyBotUITests` | XCUITest overlays (Xcode) |

Xcode tests:

```bash
xcodegen generate
xcodebuild -project GrizzyBot.xcodeproj -scheme GrizzyBot -destination 'platform=macOS' test
```

## Sign, notarize, publish an update

Debug and CI stay ad-hoc (`CODE_SIGN_IDENTITY = -`). Notarization needs a Developer ID:

1. Copy `Configs/Team.xcconfig.example` → `Configs/Team.xcconfig` and put your team id there (file is gitignored).
2. Archive / `xcodebuild -configuration Release`, or `./Scripts/make-app.sh` with `GRIZZYBOT_DEVELOPMENT_TEAM` set.
3. `./Scripts/notarize.sh GrizzyBot.app` (notarytool keychain profile `GrizzyBot-notary` by default).
4. Wrap a DMG, then `./Scripts/publish-update.sh GrizzyBot.dmg` to sign it with Sparkle and insert an `<item>` into `appcast.xml`.
5. Push `appcast.xml` and attach the DMG to a GitHub release. Installed apps then see Check for Updates.

Crash reports go to Sentry when a DSN is saved in Settings → Diagnostics (or `SENTRY_DSN`). `last-crash.txt` is always written locally.

## Chat

Connect a model in the picker so bots can think and call tools. Without a model, phrase cues still work: `spawn a bot named Scout`, `use a subagent`, `remember …`, `write a note that says Hello.`, `sign in`, `delete the bot named Scout`.
