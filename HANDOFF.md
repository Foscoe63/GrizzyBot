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

CI (`.github/workflows/ci.yml`): `swift test`, `xcodegen generate`, `xcodebuild` (app + overlay golden tests + UI tests).

Release (`.github/workflows/release.yml`): import Developer ID P12, Release build, notarize app + DMG, GitHub release. Needs repo secrets (see README).

## Architecture

| Target | Role |
|---|---|
| `GrizzyBotCore` | Models, store, agent loop, MCP, Composio, Keychain secrets, PBKDF2 auth, persistence, backup, diagnostics scrubber |
| `GrizzyBot` | SwiftUI shell, TTS, Sentry + scrubber, Mac Accessibility computer-use, overlays |
| `GrizzyBotRoutineAgent` | LaunchAgent helper — wakes app with `-grizzybot-tick-routines` when routines are due |
| `GrizzyBotCoreTests` | Swift Testing (store, agent, security, cron, product surface) |
| `GrizzyBotAppTests` | Overlay PNG golden regression (`Tests/GrizzyBotAppTests/Goldens/`) |
| `GrizzyBotUITests` | XCUITest overlays (`-uitest-open-*`) |

`GrizzyBotApp.swift` is `@main`. Agent loop: `AgentLoop` + tools; `ScriptedRuntime` when no model is connected.

## Security

- **Secrets:** API keys, Composio, Box, TTS, Sentry DSN, OAuth, connection tokens → Keychain (`SecretStore`). JSON on disk and export/backup/snapshots are stripped.
- **Passwords:** PBKDF2-HMAC-SHA256 (600k iterations prod; 2k under XCTest). Legacy SHA-256 upgraded on sign-in.
- **Local account:** Launch uses `local@grizzybot.local` without a password gate. Optional sign-up/sign-in for named accounts.
- **Diagnostics:** Run logs and crash copy use `DiagnosticScrubber` (keys, tokens, home paths). Sentry `beforeSend` uses the same scrubber.
- **Computer:** In-app browser (WKWebView, http/https only) or This Mac (AX + Screen Recording). No Docker/cloud VM — UI only offers Auto, In-app browser, This Mac, Off.

## Product notes

- **Computer host prompt:** In-app browser vs This Mac (legacy `docker` → in-app browser).
- **Background routines:** Settings → Background routines registers `SMAppService.agent` (signed Release). Agent runs `open -g -a GrizzyBot --args -grizzybot-tick-routines`; app ticks headlessly (`NSApp.setActivationPolicy(.prohibited)`) and exits when runs finish.
- **Launch at login:** SMAppService main app; Debug/ad-hoc builds show an honest status message in Settings.
- **Signing:** Debug ad-hoc. Release: `Configs/Team.xcconfig` + `GrizzyBot.Release.entitlements` (iCloud). `Scripts/notarize.sh`.
- **iCloud:** Container `iCloud.com.grizzybot.app` — see `Configs/iCloud-setup.md`.
- **Overlay goldens:** `UPDATE_SNAPSHOTS=1 xcodebuild test -only-testing:GrizzyBotAppTests` to refresh PNGs.

## Tests

Prefer TDD for store/catalog/MCP/security. After adding Swift files: `xcodegen generate`. Full suite: `swift test` + Xcode app/UI tests.
