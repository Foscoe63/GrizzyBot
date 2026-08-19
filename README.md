# GrizzyBot

Native macOS app for a team of AI agents. Each bot has its own chat, files, memory, computer, routines, and tools. Connect a cloud or local model and bots run a real tool-calling loop. Without a model, a scripted fallback still drives the UI so you can explore offline.

Requires **macOS 15+**, **Xcode 16+ / Swift 6**. Version **1.1**.

---

## What you get

### Accounts and workspaces

- Optional email sign-up, or continue with a local workspace on this Mac.
- Each signed-in account is a separate workspace under Application Support: bots, chats, settings, and files do not mix across accounts.
- Passwords use PBKDF2. Secrets live in Keychain, not in JSON on disk.

Workspace layout:

```
~/Library/Application Support/GrizzyBot/users/<userId>/
  workspace.json      bots, threads, routines, settings
  SHARED.md           memory every bot on this account can read
  homes/<botId>/      that bot’s private files (MEMORY.md, notes, shell cwd)
  skills/             imported SKILL.md folders
```

### Bots

Create bots from templates or from scratch:

| Template | For |
|---|---|
| Coworker | General work — files, search, memory, computer |
| Researcher | Web search, cited notes, saved briefs |
| Writer | Markdown reports, CSV tables, HTML slides |
| Coder | Read, edit, and run code in the bot home |
| Operator | Drive the in-app browser or this Mac |

Each bot has a name, instructions, enabled skills/tools, optional per-bot model, and its own home folder. Spawn child bots or a short-lived subagent from chat. Rooms group several bots in one conversation.

### Chat

- Markdown replies, tool cards, and live “thinking… step N” while the agent runs.
- Search chats (⌘F), edit a send, regenerate, branch, undo send (⌘⇧Z).
- Attach files into the bot home (`inbox/`).
- Dictation, speak replies (ElevenLabs or macOS TTS), and a finish notification when a run completes.

### Agent loop

When a model is connected, each send runs a tool-calling loop (up to 48 steps) with context compaction on long threads. Screenshots attach only when the model can actually see images. Empty web searches stop instead of retrying forever. Transient 429/5xx errors retry.

Without a model, scripted replies still create files, open the computer, and exercise the UI.

---

## Tools

Bots only get the tools you enable. Built-ins:

**Files** — `write_file`, `read_file`, `edit_file`, `move_file`, `delete_file`, `list_files`. Default cwd is the bot home. Absolute paths on this Mac are allowed for reads/lists; shell writes stay sandboxed.

**Shell** — `shell` runs `zsh -lc` in the bot home. Needs approval unless the bot is set to auto-approve. Timeout 5–300s (default 120).

**Web** — `web_search` / `web_fetch`. Optional Brave Search key; otherwise DuckDuckGo + Wikipedia. Research skill stops after failed/empty searches instead of looping.

**Memory** — `remember`, `search_memory`, `forget`. See [Memory](#memory).

**Computer** — `computer_open`, `computer_screenshot`, `computer_click`, `computer_scroll`, `computer_type`, `computer_key`, `request_takeover`. See [Computer](#computer).

**Team** — `spawn_bot`, `delete_bot`, `run_subagent`.

**Plugins & skills** — `plugin_call`, `destination_write`, `read_skill`, `import_skills`. Plus any MCP servers or custom tools you add.

---

## Skills

Skills are SKILL.md playbooks. Matching skills inject into the turn; others load via `read_skill`.

Bundled:

- **research** — search, fetch, cite, write a brief
- **browser** — screenshot, click, scroll, type, take over for login
- **office-docs** — markdown / CSV / HTML deliverables in `notes/`
- **coding** — read, edit, run inside the bot home
- **memory** — pin, remember, forget
- **skill-creator** — author a new SKILL.md

Import a folder of `SKILL.md` files (for example `~/.agents/skills`) with `import_skills` or Settings → Skills.

---

## Computer

Two real hosts — no cloud VM or Docker:

| Mode | What it is |
|---|---|
| Auto | In-app browser unless the bot is set otherwise |
| In-app browser | Persistent WKWebView, Safari-like user agent, http/https only |
| This Mac | Screenshot + Accessibility clicks on the main display |
| Off | Computer tools disabled |

Workflow: open a URL → screenshot (JPEG + a **Targets** list in the same pixel space) → click / scroll / type / key. Clicks can be right-click or double-click. Keys accept chords (`cmd+c`, `shift+enter`). If there is no screenshot yet, one is taken before the click.

Login, captcha, or 2FA: the bot calls `request_takeover` and you drive. Headless routine ticks skip This Mac tools (no Screen Recording session).

Settings → Computer shows Accessibility and Screen Recording status with deep links to System Settings.

---

## Memory

- **Bot** — `homes/<botId>/MEMORY.md`
- **Shared** — `SHARED.md` at the workspace root (every bot on this account)

`remember` upserts similar facts instead of duplicating. Standing rules go under `## Pin` (`pin: true` or `scope: pin`) and always load in the prompt. Recent facts go under `## Facts`. `search_memory` is BM25 over this bot plus shared — sibling bots are not leaked. Secret-shaped strings (API keys, passwords) are refused.

Edit memory in the bot panel or Settings → Shared memory.

---

## Routines

Cron jobs that send a prompt to a bot.

- Scheduler while the app is open (cap two concurrent routine runs).
- **Background routines** (signed Release): a LaunchAgent helper wakes the app with `-grizzybot-tick-routines`. If GrizzyBot is already open, the helper pings it and exits. Headless ticks wait up to 15 minutes for runs to finish.
- Menu bar lists upcoming routines and runs a specific one, not “whatever is first.”
- Due routines with no model skip honestly and still advance `nextRunAt`.

---

## Models

GrizzyBot does not pay for usage. You bring a key, a subscription, or a local server.

**Cloud (API key)** — OpenRouter (default), OpenAI, Anthropic, Google, Mistral, Groq, DeepSeek, xAI.

**Subscriptions (device-code sign-in)** — ChatGPT Plus/Pro (OpenAI Codex), GitHub Copilot, SuperGrok / X Premium.

**Local / LAN** — Ollama, LM Studio, vMLX, oMLX (discovery + live model list), plus any OpenAI-compatible base URL.

Each provider keeps its own profile. A bot can use the workspace default or a catalog model. Vision images are sent only to models that can take them (text-only IDs such as DeepSeek chat or Groq Llama 3 are not stuffed with screenshots).

---

## Plugins, MCP, destinations

**Plugins** — Composio Connect OAuth, or paste a token. Catalog includes Gmail, Slack, GitHub, Notion, Linear, Google Calendar/Sheets/Docs/Drive, HubSpot, Salesforce, Jira, Trello, Asana, Intercom, Discord, X, Stripe, Dropbox, Box, Figma, Airtable. `plugin_call` can search/list/get or write.

**MCP** — stdio, streamable HTTP, or legacy SSE. Each server is a toggleable tool (`mcp:<id>`). Homebrew is prepended on PATH for GUI-launched stdio servers.

**Custom tools** — phrase-match replies if you still have them; prefer MCP for new tools.

---

## App chrome

- Sidebar of bots, rooms, routines, plugins, skills, weekly usage.
- Settings: General, Connections, Computer, Voice, Tools, Themes, Diagnostics.
- Themes: Grizzy (default), system, light, dark, and the built-in gallery.
- Menu bar extra; optional menu-bar-only (no window until you open it).
- Launch at login (signed Release; Debug/ad-hoc shows an honest status).
- Dictation + TTS (ElevenLabs key or macOS voices).
- Optional Brave Search key; optional Sentry DSN.
- Snapshots, redacted export, iCloud backup (container `iCloud.com.grizzybot.app` when team-signed), wipe workspace.

---

## Security

- API keys, Composio, Box, TTS, Sentry, OAuth, and connection tokens → Keychain. Workspace JSON, exports, backups, and snapshots are stripped.
- Diagnostics and Sentry events scrub keys, tokens, and home paths.
- Shell write seatbelt stays inside the bot home unless approved.
- In-app browser: http/https/about only; desktop HTML escapes filenames.
- Computer-use is local only (WKWebView or Accessibility). No remote desktop VM.

Crash reports: Settings → Diagnostics. Local `last-crash.txt` is always written; Sentry is optional.

---

## Build

```bash
swift build
xcodegen generate   # after editing project.yml
open GrizzyBot.xcodeproj
```

Release app bundle:

```bash
chmod +x Scripts/make-app.sh Scripts/notarize.sh
./Scripts/make-app.sh
```

## Test

```bash
swift test
xcodebuild -project GrizzyBot.xcodeproj -scheme GrizzyBot \
  -destination 'platform=macOS,arch=arm64' test
```

Overlay golden refresh (shell `UPDATE_SNAPSHOTS` does not reach the test host). Touch a marker file, then run app tests:

```bash
touch Tests/GrizzyBotAppTests/Goldens/.refresh
xcodebuild test -project GrizzyBot.xcodeproj -scheme GrizzyBot \
  -destination 'platform=macOS,arch=arm64' -only-testing:GrizzyBotAppTests
rm Tests/GrizzyBotAppTests/Goldens/.refresh
```

Live model evals are gated on `GRIZZYBOT_LIVE_EVAL=1`.

## Architecture

| Target | Role |
|---|---|
| `GrizzyBotCore` | Domain, agent loop, Keychain, persistence, MCP, Composio |
| `GrizzyBot` | SwiftUI app, computer-use, TTS, Sentry |
| `GrizzyBotRoutineAgent` | LaunchAgent helper for background routine ticks |
| `GrizzyBotCoreTests` | Unit tests (Swift Testing) |
| `GrizzyBotAppTests` | Overlay golden PNGs (host launches a lightweight test path) |
| `GrizzyBotUITests` | XCUITest overlays (`-uitest-open-*`) |

`GrizzyBotApp.swift` is `@main`. Persistence is per-user under Application Support. The Xcode project is generated from `project.yml`.

## Sign, notarize, publish

1. Copy `Configs/Team.xcconfig.example` → `Configs/Team.xcconfig` (gitignored) with your team ID.
2. Create iCloud container `iCloud.com.grizzybot.app` — see `Configs/iCloud-setup.md`.
3. `./Scripts/make-app.sh` (or Release archive) with team config.
4. `./Scripts/notarize.sh GrizzyBot.app` — keychain profile `GrizzyBot-notary` by default.
5. Wrap in a DMG and upload to a GitHub release.

Or tag `v*` to run `.github/workflows/release.yml` (`GRIZZYBOT_DEVELOPMENT_TEAM`, `DEVELOPER_ID_APPLICATION_P12`, `DEVELOPER_ID_APPLICATION_P12_PASSWORD`, `NOTARY_KEYCHAIN_PROFILE`).

You still do Apple Developer ID, notarize credentials, the iCloud container, Accessibility / Screen Recording, and API keys yourself. Those are not in the repo.
