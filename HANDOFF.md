# GrizzyBot — Handoff

**Last updated:** 2026-08-18  
**Version:** 1.1 (build 2)

Native macOS Swift 6 app. Core is `GrizzyBotCore` (no SwiftUI). UI is `Sources/GrizzyBot`. Persistence: `~/Library/Application Support/GrizzyBot/`. Do not touch `config.json` / `.omo/`. Do not commit secrets. Xcode project is generated: `xcodegen generate`.

## Commands

```bash
swift test
swift build
xcodegen generate
./Scripts/make-app.sh
```

CI (`.github/workflows/ci.yml`): `swift test`, `xcodegen generate`, `xcodebuild`.

## Architecture (do not re-implement)

| Target | Role |
|---|---|
| `GrizzyBotCore` | Models, store, agent loop, MCP, Composio, persistence, search, backup, TTS request builder |
| `GrizzyBot` | SwiftUI shell, Sparkle, ElevenLabs playback, crash dump, overlays |
| `GrizzyBotCoreTests` | Swift Testing — including ProductSurfaceTests for chat search, paste guard, composer Return, catalog filter, secrets, undo/edit/branch |

`GrizzyBotApp.swift` is the real `@main` app (RootView, menu bar, Sparkle, commands). The agent is `AgentLoop` + tools, with `ScriptedRuntime` only as the offline fallback when no model is connected.

## Product notes

- Per-bot model: right panel Settings → Model. Workspace default vs catalog override (`Bot.modelId` / `modelProvider`).
- Tool restrictions: disabling Shell or Computer shows a chat banner; the model does not get those tools.
- TTS: ElevenLabs when a key is saved; otherwise macOS `AVSpeechSynthesizer`.
- Device-code OAuth is the first card on Connect (ChatGPT / Copilot / SuperGrok). Settings → Connections also opens that sheet.
- Chat: search (⌘F), edit & resend, regenerate, branch to a task, undo send (⌘⇧Z).
- Keys: Clear on each secret row. Empty save keeps the stored value.
- Diagnostics: Settings → Diagnostics — copy last run log / last crash. MCP stderr is appended to the run log.
- Backup: Settings → General → Backup to iCloud. Prefers `iCloud.com.grizzybot.app` when the Release entitlements are used; otherwise `~/Library/Mobile Documents/com~apple~CloudDocs/GrizzyBot Backups`, then Documents.
- Sparkle: Check for Updates runs in Debug and Release. `SUFeedURL` → `appcast.xml`. Publish a signed DMG with `Scripts/publish-update.sh`. Private key: `Scripts/sparkle_eddsa_private.key` (gitignored).
- Signing: Debug is ad-hoc. Release uses `Configs/Team.xcconfig` (from `Team.xcconfig.example`) for Developer ID + iCloud entitlements. `Scripts/notarize.sh` runs notarytool.
- Crash reporting: Sentry when a DSN is set (Settings → Diagnostics). Local `last-crash.txt` always.
- UI tests: `GrizzyBotAppTests` snapshots overlays; `GrizzyBotUITests` launches with `-uitest-open-*`.
- Computer-use: `NSAccessibilityUsageDescription` plus Screen Capture / Apple Events strings. Hardened Runtime entitlements: Apple Events + microphone. iCloud container only on Release entitlements. App is **not** sandboxed.
- Context: local models use a 24k char budget; huge user pastes are compacted; the composer warns on vault-shaped dumps.

## Tests

Prefer TDD for store/catalog/MCP. After adding Swift files: `xcodegen generate`. Full suite: `swift test`.
