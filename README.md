# GrizzyBot

Native macOS app for a team of always-on AI agents — bots you chat with, each with its own thread, computer, routines, memory, and plugins. Offline and self-contained: a local scripted agent drives the full product loop (no network, Postgres, or Docker required).

UI and settings mirror the sibling `rakazo` project. Branding is **GrizzyBot**.

## Requirements

- macOS 15+
- Xcode 16+ / Swift 6

## Build

```bash
swift build
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
- **Sidebar of bots** — search, status, previews, plugins entry, weekly usage, log out
- **Chat** — markdown bubbles, cards, asks, subagents, child bots, routines meta, working… pulse, stop
- **Computer panel** — boot overlay, take control / release, full-window desktop placeholder, this-Mac vs Docker host prompt
- **Routines** — schedule picker (cron presets), run now
- **Plugins** — connect / revoke catalog apps (simulated OAuth)
- **Settings** — edit, export JSON manifest, delete (child bots remain)
- **Local persistence** — `~/Library/Application Support/GrizzyBot/`

## Architecture

| Target | Role |
|---|---|
| `GrizzyBotCore` | Domain models, cron, model catalog, scripted runtime, persistence, `AppStore` |
| `GrizzyBot` | SwiftUI app |
| `GrizzyBotCoreTests` | Cron, ScriptedRuntime, Store suites |

## Scripted chat cues

Try messages like: `spawn a bot named Scout`, `use a subagent`, `remember …`, `write a note that says Hello.`, `sign in`, `delete the bot named Scout`.
