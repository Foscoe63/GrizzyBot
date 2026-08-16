# GrizzyBot — Handoff Document

**Last updated:** 2026-08-16
**Status:** Complete — core, SwiftUI, tests, and packaging all land. `swift build` / `swift test` exit 0; `Scripts/make-app.sh` builds a launchable `GrizzyBot.app`.

Read this file top-to-bottom before doing anything else. It is self-contained: you do **not** need the rakazo repo to finish this project (its location is listed in §8 for reference only).

---

## 1. Mission

Build **GrizzyBot**, a native macOS app in the latest Swift (Swift 6.3 / Xcode 27 on this machine), whose **GUI interface and GUI settings are exactly like the rakazo project** (an open-source TypeScript/React/Electron "AI teammates" app). Do not skip any settings or abilities. When complete: build, test, fix all errors, and verify the app launches.

Interpretation decisions already made (keep them):
- Branding is **GrizzyBot** everywhere rakazo shows its own name ("Sign in to GrizzyBot", "Open GrizzyBot", wordmark, etc.). Layout, colors, spacing, copy (except the product name), and behavior are identical to rakazo.
- The app is **self-contained**: no network, no Postgres, no Docker. A local scripted agent (mirroring rakazo's `scripted-runtime.ts`) makes the full product loop work offline: create bots, chat, spawn child bots, run subagents, routines, computer panel with take-control/release, plugins connect/revoke, export/delete bot.
- Architecture: SPM package with a **`GrizzyBotCore` library** (no SwiftUI, fully unit-testable) + a **`GrizzyBot` executable** (SwiftUI app). Swift 6 strict concurrency is ON — keep models `Sendable`, put the store on `@MainActor`.

## 2. Environment & commands

- macOS 27.0 arm64, Xcode 27.0, Swift 6.3 (`swift --version` to confirm on the new machine).
- Project root: this folder (contains `Package.swift`).
- Build: `swift build` — must exit 0 with no errors.
- Test: `swift test` (Swift Testing framework, `import Testing`).
- Package layout is fixed in `Package.swift`: targets `GrizzyBotCore` (Sources/GrizzyBotCore), `GrizzyBot` executable (Sources/GrizzyBot), tests in Tests/GrizzyBotCoreTests. Platform: macOS 15+.
- **Do not touch** pre-existing files in this folder that are not part of the Swift project: `config.json` (MCP config) and `.omo/`.

## 3. Done so far (all verified: `swift build` exit 0, `swift test` exit 0)

| File | Contents |
|---|---|
| `Package.swift` | swift-tools-version 6.0, macOS(.v15), the three targets above |
| `Sources/GrizzyBotCore/Cron.swift` | Exact port of rakazo `packages/core/src/cron.ts`: `Cron.freqs/units/times/numbers`, `Preset` struct, `defaultPreset()`, `fromPreset(_:)`, `preset(fromCron:)`, `describe(_:)` → (lead, detail), `formatSchedule`, `formatCron`, `nextDate(_:from:)`, plus private helpers `parseClock/formatClock/stepValue/isInt/matchField`. All rakazo test expectations hold (e.g. `Every day 9:00 AM` → `"0 9 * * *"`, `Weekdays 8AM` → `"0 8 * * 1-5"`, `*/15 minutes` → `"Every 15 minutes"`). |
| `Sources/GrizzyBotCore/Models.swift` | All domain models mirroring rakazo contracts: `botColors` (7 hex colors, exact order from `packages/contracts/src/ids.ts`), `Bot`, `CardLine`, `ChoiceOption`, `SubagentStatus`, `ChildBotStatus`, `ConnectStatus`, `MessageBlock` enum (10 cases: text, card, ask, choice, connect, computer, meta, progress, subagent, childBot), `MessageRole`, `ThreadMessage` (with `firstText` for sidebar preview), `RunStatus` (8 values, `isActive` = queued/leased/running — the "working…" pulse states), `Run`, `SandboxKind` (docker/e2b/desktop/fake), `ComputerState` (stopped/booting/running/suspended/error), `ControlHolder` (bot/user/none), `ComputerStatus`, `Routine`, `ConnectionItem`, `UsageRecord`, `UsageSummary`, `MemoryDocument`, `ExportManifest` (+ nested BotExport/MemoryEntry/RoutineExport/FileEntry), `UserAccount`, `Session` (with `initials`), `DeploymentSettings` (`computerHost`: "docker"/"this-mac"/nil, `sandboxKind`), `ThreadData`, `Ids.new()`. |
| `Sources/GrizzyBotCore/ModelCatalog.swift` | `CatalogEntry` (provider, providerName, id, label, billing, auth: api-key/oauth/both, oauthLabel, subscription, signIn: device-code) + `ModelCatalog`: 10 providers / ~25 models. Default provider `openrouter`, default model `deepseek/deepseek-v4-flash-0731`. Device-code providers: `openai-codex` (hint "ChatGPT Plus/Pro", label "Sign in with ChatGPT Plus/Pro"), `github-copilot` (hint "Copilot", label "Sign in with GitHub Copilot"), `xai` (hint "SuperGrok / key", label "Sign in with SuperGrok or X Premium"). Also `providers` rail (first model per provider), `models(forProvider:)`, `hint(for:)` (exact strings from rakazo Onboarding.tsx `providerHint`), `signInLabel`, `verificationURI(forProvider:)` (simulated activation URLs), `makeUserCode()` (XXXX-XXXX style). |
| `Sources/GrizzyBotCore/ScriptedRuntime.swift` | Exact port of rakazo `inferScript`: `reply(to:) -> ScriptedReply(text, action?)` with all 9 branches in rakazo's order and exact text: (1) "completed sign-in"/"continue without requesting takeover" → signed-in message; (2) "take over"/"sign in"/"login" → takeover action; (3) "delete the bot named X" → deleteBot(name); (4) "spawn a bot"/"create a bot named X" → spawnBot; (5) "subagent"/"delegate to a helper" → subagent(task); (6) "connector"/"crm"/"destination" → destinationWrite; (7) "write … file/home/note" (+ `says?` capture, trailing dots stripped, trimmed) → writeFile notes/result.txt; (8) "remember" → remember(text); (9) default → "on it. i will work this in the background…" + writeFile notes/last-task.md. Plus `subagentResult(for:)` = "done. i handled: {task≤180}". |
| `Sources/GrizzyBot/GrizzyBotApp.swift` | **STUB ONLY** — `@main` App with a placeholder `Text("GrizzyBot")`, `.windowStyle(.hiddenTitleBar)`, `.defaultSize(width: 1280, height: 832)`. Replace with the real app (see §5.1). |
| `Tests/GrizzyBotCoreTests/SmokeTests.swift` | 2 passing smoke tests (bot colors, default cron). Replace/extend with the real suites in §6. |

## 4. Remaining work — Core (Sources/GrizzyBotCore/)

### 4.1 `Persistence.swift`
- Data dir: `~/Library/Application Support/GrizzyBot/` (create if missing).
- Files: `users.json` (`[UserAccount]`), `session.json` (`Session?`), `user-{userId}.json` (a `UserWorkspace` struct: bots, threads `[String: ThreadData]`, routines `[String: [Routine]]`, computers `[String: ComputerStatus]`, connections `[ConnectionItem]` (catalog with connected flags), usage `[UsageRecord]`, memory `[MemoryDocument]`, files `[[path, content]]` (bot home files written by the scripted runtime), deployment `DeploymentSettings`).
- Passwords: SHA-256 hex via CryptoKit (`import CryptoKit`), never plaintext.
- Load on store init; save (atomic JSON, pretty-printed) after each mutation. Keep it simple: one `save()` call at the end of each mutating store method.

### 4.2 `Store.swift` — `@MainActor @Observable final class AppStore`
This is the heart. Mirror rakazo's Shell.tsx state + API behavior locally:

**Routing/auth:**
- `enum Route { case welcome, signIn, signUp, onboarding, shell }`; `var route: Route`.
- On launch: load session → if user exists and has bots → `.shell`; user without bots → `.onboarding` (rakazo Shell redirects empty bot lists to onboarding); no session → `.welcome`.
- `signUp(name,email,password) -> String?` (error): validate email contains "@" and ".", password ≥ 8 chars; duplicate email → `"An account with this email already exists."` (Better Auth's exact message). Name defaults to local part of email, else "User".
- `signIn(email,password) -> String?`: unknown email or bad hash → `"Invalid login credentials"`.
- `signOut()`: clear session, route `.welcome` (data stays).

**Bots:**
- `createBot(name,title,description,instructions,parentBotId?) -> Bot`: color = `botColors[count % 7]` (rakazo repos.ts behavior); creates thread + computer (`kind` from deployment: "this-mac" → `.desktop`, else `.docker`; state stopped) + initial memory doc.
- `updateBot(botId, name?, title?, description?, instructions?)`; `deleteBot(botId)`: removes bot + thread + computer + routines; **child bots stay** (their `parentBotId` just dangles — rakazo keeps them in the list).
- `bots: [Bot]`, `activeBotId: String?`. Sidebar preview = last message's first text (truncated ~80 chars) else `bot.title`; status = "working" while that bot's run is active, else "idle".

**Threads (the chat loop):**
- `send(botId, text)`: append user message (`role .user`, one `.text` block), create `Run(status: .running, trigger: "user")`, then a `Task` that simulates the agent (rakazo shows a pulsing "working…" bubble while run is active):
  - ~0.9s: append a `.progress` block message (streaming bubble, text "working…") — or just rely on the run-status pulse; rakazo does both (progress events + run status).
  - ~1.6s: compute `ScriptedRuntime.reply(to: text)`; append the bot message with `.text(reply.text)` plus action-specific blocks (below); execute side effects; set run `.completed`; record usage (`inputTokens: 12, outputTokens: 40` — rakazo scripted runtime values); update bot preview/status; save.
- Action side effects (append blocks to the same or new messages, mirroring rakazo UI):
  - `.spawnBot(name,title)`: create child bot (parentBotId = active), append `.childBot(botId, name, title, .created)` block. Clicking that card navigates to the child (Shell `onOpenBot`).
  - `.deleteBot(name)`: find bot by name, delete it, append `.childBot(botId, name, nil, .deleted)` block.
  - `.subagent(task)`: append `.subagent(agentId, name: "helper", task, .running, progress: "working…", result: nil)`; after ~1.5s update that block to `.completed` with `result = ScriptedRuntime.subagentResult(for: task)`.
  - `.takeover(reason)`: set computer `controlHolder = .user` (rakazo's `computer.takeover.granted`), run status `.waitingTakeover`.
  - `.remember(text)`: upsert memory doc `MEMORY.md` (scope bot, content "# Memory\n\n- {text}\n"), store in workspace.
  - `.writeFile(path, content)` / default action: store file entry (bot home), and for the write branch also append a `.card(lines:)` block with one line `k: path, v: content.trimmed`.
  - `.destinationWrite(title, body)`: append a `.card` block `k: title, v: "recorded"`.
- `stopRun(botId)`: cancel the pending Task, run → `.cancelled`, remove any in-flight progress message.
- `answerAsk(botId, answer)`: for the "Send it" button → append bot text `"done — sent."` (local simulation of `rpc.threads.answer`).
- Keep a `[String: Task<Void, Never>]` (runId → task) so stop works. All delays via `try? await Task.sleep(for: .seconds(x))`; check cancellation between steps.

**Computer:**
- `boot(botId, force:)`: state `.booting` + `booting = true` (drives the full-screen boot overlay); after ~2.5s → `.running`, `screenAvailable = true`, `booting = false`. There is **no real screen URL** — rakazo's UI then shows the text placeholder `"{name}'s screen"` (that is exactly what rakazo renders when running without an embeddable URL).
- `takeControl(botId)` → `controlHolder = .user`; `release(botId)` → `.bot`.
- Auto-boot when the computer panel opens and state is stopped (rakazo `autoBooted` effect).
- `computerOpen: Bool` = full-window computer overlay (Escape closes it, like rakazo).

**Routines:**
- `createRoutine(botId, name, prompt, cron, timezone: "UTC", active: true, notify: true)`; list per bot.
- `runNow(botId)`: rakazo runs the **first** routine: append a `.meta` message `"Routine '{name}' fired"` (centered ◷ row), then run the scripted reply for `routine.prompt` as a bot message (trigger "routine").

**Plugins:**
- Built-in catalog (~12 apps, all OAuth-style): gmail/Gmail, slack/Slack, github/GitHub, notion/Notion, linear/Linear, google-calendar/Google Calendar, hubspot/HubSpot, salesforce/Salesforce, jira/Jira, trello/Trello, asana/Asana, intercom/Intercom. `logo: nil` (UI shows the initial in a rounded square).
- `connect(slug)`: pending ~1.2s → connected (simulated OAuth; no real browser). `revoke(slug)`: pending ~0.8s → not connected.

**Usage:**
- `weeklySummary() -> UsageSummary`: records from the last 7 days → runs count + total input/output tokens (shown in the user menu as `"{runs} runs · {tokens} tokens"`).

**Export:**
- `exportManifest(botId) -> ExportManifest`: version 1, bot {name,title,description,instructions}, memory entries, routine exports, file entries (bot home), history = all thread messages. The view layer writes it via `NSSavePanel` to `{name-lowercase-spaces-to-dashes}-export.json` (rakazo's exact filename rule).

**Deployment / host prompt:**
- `deployment: DeploymentSettings` (persisted per user). On first shell entry with `computerHost == nil`, show the HostComputerPrompt overlay (native app ⇒ always "this Mac" wording). Choosing sets `computerHost` and the sandbox kind for **new** bots.

## 5. Remaining work — Views (Sources/GrizzyBot/)

Design system first, then screens in this order: Theme → Controls → BotAvatarView → MarkdownText → Welcome → Auth → Onboarding → Shell (Sidebar, Chat, MessageViews, RightPanel) → RoutineScheduleView → PluginsOverlay → HostComputerPrompt → overlays. Then wire `RootView` into the real `GrizzyBotApp`.

### 5.0 Theme.swift — exact rakazo palette
```
bg app dark        #050506     bg welcome       #08080A
bg sidebar         #0B0B0C     bg main          #0D0D0E
bg right panel     #0A0A0B     bg auth (light)  #F7F7F4
border sidebar     #171719     border main hdr  #141416
border inputs dark #26262A     border list rows #202023 / #232326
text primary       #DFDFE2     text bright      #ECECEE / #F1F1F2
text secondary     #85858A     text muted       #6C6C70
cream button bg    #F1F1EF     cream text       #17171A
dark button bg     #121215 / #1B1B1F  (hover #26262B)
orange             #E65707     green            #4ECB71 / #30A24B
red error          #C94244     traffic lights   #FF5F57 #FEBC2E #28C840
auth input bg      #F1F1ED     auth border      #E4E4DE
auth title text    #1B1B1E     auth label       #6E6E68
welcome tagline    #E4E4E6     welcome logo bg  #F2F2F0
```
Font: system font (SF Pro) at the exact CSS px sizes below (1px = 1pt). rakazo uses Geist; system is the native equivalent.

### 5.1 GrizzyBotApp.swift (replace stub)
`WindowGroup { RootView().environment(store).frame(minWidth: 1080, minHeight: 720) }`, `.windowStyle(.hiddenTitleBar)` (native traffic lights overlay the dark UI — rakazo's Electron darwin mode does exactly this), `.defaultSize(width: 1280, height: 832)`. `@State private var store = AppStore()`.

### 5.2 RootView.swift
Switch on `store.route`: welcome / auth(mode) / onboarding / shell. (Loading state not needed locally.)

### 5.3 BotAvatarView.swift
Circle filled with `color`. Inside: a "visor" — width 68% of size, height 40%, corner radius = 55% of visor height, fill `rgba(12,12,14,0.78)`, containing two white dots of diameter `max(3, size*0.1)` with gap `max(4, size*0.13)`. Sizes used: 38 (sidebar), 26 (header), 28 (computer overlay header), 64 (settings).

### 5.4 Controls.swift
- `GrizzyButton` variants (from rakazo button.tsx): default (bg #121215, text #FBFBF9), cream (bg #F1F1EF, text #17171A), outline (border #26262A, text #ECECEE, hover bg #1A1A1D), ghost (text #C9C9CE), pill (rounded-full, bg #1B1B1F, text #F2F2F3). Sizes: default h40 px16, sm h32 px12 text13, lg h48 px24 text17. Corner radius 13 (pill = full). Disabled: opacity 0.4–0.5, no action.
- Note: many rakazo buttons are raw `<button>`s with their own classes (e.g. onboarding "Continue" = rounded-11 bg #F1F1EF px20 py10 text14). Match each usage site exactly rather than forcing one component.
- `GrizzyField` (dark): rounded 11, border #26262A, transparent bg, px14 py12, text 15–17 #ECECEE; label above in 13–14px #85858A. Auth (light) variant: rounded 13, border #E4E4DE, bg #F1F1ED, px18 py17, text 17 #1B1B1E.
- `GrizzySelect`: custom dropdown (button + popover list) because native menus can't be styled. Two styles: **field** (onboarding Model select: rounded 11, border #26262A, px14 py12) and **chip** (schedule selects: bg #24242A, rounded 8, px11 py7, text 14 #ECECEE, chevron svg 12px stroke #9A9AA0 at right-8).
- `Pulse` modifier = rakazo `rkPulse`: opacity 1 → 0.3, ease-in-out, 1.2s, infinite repeat (use `.animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value:)` toggled on appear).
- Scrollbars: thin (6px) dark thumb #2A2A2E where rakazo uses `.rk-scroll` (sidebar list, chat, right panel, plugins list).

### 5.5 MarkdownText.swift
Lightweight renderer for chat bubbles (rakazo uses react-markdown + GFM): split into lines; ``` code fences → monospaced block (bg #0E0E10, rounded 12, px14 py12, text 12.5 #85858A); `#`/`##`/`###` → bold, larger; `- `/`* `/numbered bullets → indented with marker; other lines → paragraphs. Inline styles (bold/italic/code/link) via `AttributedString(markdown:)` per line. While a message is streaming (progress block / running subagent), append a blinking "▍" cursor.

### 5.6 WelcomeView.swift
bg #08080A, full column. Top bar: 72×12 spacer at left (traffic-light zone; rakazo darwin `WindowChrome` = spacer). Centered stack, gap 44: (a) row gap 26: logo circle 88 bg #F2F2F0 with two vertical bars (h24 w11, gap 13, bg #101012) + "GrizzyBot" text 76px, tracking −0.03em, white; (b) tagline 27px #E4E4E6, two lines: "Your team of always-on agents" / "that you can give real work to."; (c) pill button "Sign in  →" (two spaces before arrow), bg #1B1B1F, px34 py15, text 19 #F2F2F3, hover scale 1.04 + bg #26262B → route `.signIn`.

### 5.7 AuthView.swift (mode: in/up)
bg #F7F7F4, centered 460px form. Logo circle 74 bg #16161A with two light bars (h20 w9, gap 11, bg #F7F7F4). Title 38px tracking −0.02em, mt30 mb38: "Sign in to GrizzyBot" / "Create your GrizzyBot". Sign-up only: Name field (label 16px #6E6E68, placeholder "Your name"). Email field ("Your email address", type email). Password ("Password", secure, min 8). Error text #C94244 (13px) above button. Submit: full width, rounded 13, bg #121215 (hover #26262B), py18, text 17 medium #FBFBF9: "Continue with email" / "Create account"; while pending → "Working…". Footer 16px #8C8C86 mt30: "Don't have an account? **Sign up**" / "Already have an account? **Sign in**" (link = 16px medium #1B1B1E). Success → onboarding (up) or shell (in; if no bots, store routes to onboarding).

### 5.8 OnboardingView.swift
bg #0D0D0E, centered 560px column. Steps: **model → bot → questions (×2) → done**.

*Model step:* h1 32px medium #F1F1F2 "Connect a model"; sub 14–15px #85858A: "GrizzyBot does not pay for model usage. Paste an API key, sign in with ChatGPT, Copilot, or SuperGrok, or skip if this deployment already has a key." Search input (mt32, rounded 11, border #26262A, px14 py12, placeholder "Search providers and models"). Provider rail (mt12, max height 192 scrollable, rounded 11 border #26262A): rows px14 py10, border-b #202023 (none on last), selected bg #1A1A1D else hover #161618; left = providerName 15px #ECECEE, right = hint 12px #85858A (from `ModelCatalog.hint`). Filtering: query matches provider/providerName/label/id/billing/oauthLabel (case-insensitive substring). Model select (mt16, label "Model" 13px #85858A) listing `models(forProvider:)` by label. Billing line 13px #85858A mt8. If selected model has device-code sign-in: button (cream, rounded 11 px20 py10) with `signInLabel` ("Sign in with ChatGPT Plus/Pro" etc.); while pending → "Starting…". After click: show code box (rounded 11 border #26262A px14 py12): "Enter this code at {uri without https://}" (link underlined #ECECEE), the user code 22px monospaced tracking 0.2em #F1F1F2, "Waiting for sign-in…" 13px #85858A; simulate completion after ~4s → proceed to bot step. API key field (label "API key", or "Or paste an API key" when device sign-in also available; placeholder "sk-…", secure) — shown unless auth is oauth-only (then show the note: "This provider cannot paste a key here. Skip if this deployment already has credentials."). Error #E65707 13px. Buttons row mt24 gap12: "Continue" (cream rounded 11 px20 py10) + "Skip for now" (plain text #85858A). Continue saves the chosen provider/model (+ key if provided) and goes to bot step.

*Bot step:* h1 32 "Create your first bot"; Name input (mt32, placeholder "Name this bot"), Title ("Describe what this bot does"), Description textarea rows 4 ("What this bot is for"); "Continue" cream, disabled until name non-empty.

*Questions step:* card rounded 20 bg #1A1A1D p20. Question 17px medium #F1F1F2 + sub 15px #85858A mt4. Options list (mt14, rounded 13 border #232326): rows px16 py14, gap 14, border-b #202023 (none last), hover bg #222226; letter badge 22×22 rounded 6 bg #232327 text 12.5 #9A9AA0 (A, B, C…); option text 15.5 #ECECEE. Clicking appends the answer and advances. The two questions (exact text):
1. "What do you mainly want help with?" / sub "Pick whatever's closest, or type your own." / options: "Inbox & email", "Slack & messages", "Coding & repos", "Research & writing", "A bit of everything"
2. "How do you want me to write?" / sub "I'll match this unless you say otherwise." / options: "Clear and tight", "Warm and conversational", "Polished / formal", "Match whatever I draft"

*Done step:* h1 32 "You're set." + sub #85858A "I'll pick up work the moment you send it." + button "Open GrizzyBot" (cream). On click: create the bot with `instructions = "User setup:\n- {a1}\n- {a2}"` (or the description if no answers), `notifyOnFinish: true`, then route to shell with that bot active.

### 5.9 ShellView.swift
`HStack(spacing: 0)`: Sidebar (fixed 316) + Main (flex, bg #0D0D0E) + RightPanel (animated width 0 ↔ 384, bg #0A0A0B, border-l #141416 when open). Overlays stacked on top (z-order): HostComputerPrompt, PluginsOverlay, booting overlay, computer full-window.

**Booting overlay:** bg rgba(4,4,5,0.96) full; centered column gap 22: "Booting up {name}'s computer" 19px medium #F1F1F2; progress track h5 w min(420, 70%) rounded-full bg #232327 with a 2/3-width fill #F1F1EF (indeterminate — animate the fill sliding).

**Computer full-window overlay:** column bg #050506. Header px18 py14 border-b #171719: left row gap 12 — avatar 28 + "{name}'s computer" 15.5px medium #ECECEE (truncate) + if user has control: pill "You have control" (rounded-full, bg rgba(48,162,75,0.14), px11 py4, 13px #4ECB71). Right: Take control / Release (outline sm) + "✕" 16px #85858A hover #ECECEE (closes overlay; Escape key also closes). Body bg #0E0E10: if kind == .desktop → centered text 13–14px #6C6C70 "This bot runs on this computer. There is no separate Linux desktop. Ask it to use the shell; working directories under your home folder are allowed."; else if running → centered "{name}'s screen" (no real VNC URL, same as rakazo without a screen); suspended → "Computer is asleep".

### 5.10 SidebarView.swift (w316, bg #0B0B0C, border-r #171719)
Top row (px18 pb12 pt16, space-between): 72×12 spacer (traffic lights) + "+" button 21px #7A7A80 hover #C9C9CE, title "New bot" → opens `create` panel.
Search box (mx14 mb12, rounded 12, border #202023, bg #141416, px12 py8): "⌕" glyph + input 14px #6C6C70 placeholder "Search". Filters bots by name+preview substring.
Bot list (flex-1 scroll, px10 pb10): rows rounded 12 px10 py11 gap 12, active bg #161618; avatar 38; name 15px medium #ECECEE (baseline row with status right-aligned 12.5px #6C6C70 — hidden when "idle"); preview line mt2 13.5px #85858A truncated (preview || title). Click → select bot.
Plugins button (mx12 mb4, rounded 11 px10 py8, hover bg #131315): icon circle 30 bg #17171A with the rakazo puzzle SVG (15px, stroke 1.7 #9A9AA0 — path in §8) + "Plugins" 14.5px #C9C9CE → opens PluginsOverlay.
User row (relative; px18 py14): avatar circle 32 bg #232326 with initials 12px #A8A8AD + name 14.5px #C9C9CE; click toggles menu.
User menu (when open, absolute above the row: bottom 56, left/right 12; rounded 16 border #2A2A2F bg #1A1A1D p8, shadow 0 22 50 rgba(0,0,0,.55)): row "Weekly usage" (icon "◔" #9A9AA0, text 14.5 #ECECEE) — clicking fills in `"{runs} runs · {tokens} tokens"` 12.5px #85858A below it; row "Log out" (icon "⇤") → signOut.

### 5.11 ChatView.swift (main column)
Header (px22 py17, border-b #141416, space-between): left button (avatar 26 + name 16px medium #ECECEE, truncated) → opens `settings` panel; right: computer toggle button 30×34 rounded 9 (active bg #1B1B1E) with monitor icon (rect x2 y4 w20 h13 rx2 + stand lines, 18px stroke #A8A8AD) → toggles `computer` panel.
Messages (flex-1 scroll, px28 py24, gap 13): one `MessageView` per message (see §5.12). If run active: pulsing "working…" bubble (left, rounded 20 bg #1A1A1D px18 py13, 14.5px #85858A).
Input bar (px24 pb24 pt12): pill container rounded-full border #202023 bg #131315 py9 pr10 pl12, row gap 14: "+" circle 34 border #26262A text 18 #9A9AA0 (decorative, like rakazo); input flex-1 15.5px #E9E9EA placeholder "Message {name}" (Enter sends, Shift+Enter newline); right circle 36 bg #F1F1EF text #17171A: "↑" to send, or "■" (stop) while run active.

### 5.12 MessageViews.swift — exact block rendering
- **meta**: centered row gap 8 py4: "◷" #E65707 + text 13.5px #85858A.
- **progress**: left bubble max-w 74%, rounded 20 bg #1A1A1D px18 py12, 15.5px leading 1.5 #DFDFE2, markdown + streaming cursor.
- **subagent**: card w min(420, 90%), rounded 18 border #232326 bg #17171A px18 py16: row — name 15px medium #ECECEE + status pill (rounded-full px11 py4, 13px): running → "subagent" text #F5A03C bg rgba(245,160,60,.14) + pulse; completed → #4ECB71 bg rgba(48,162,75,.14); failed → #E65707 bg rgba(230,87,7,.14). Task 13.5px #85858A mt8. Progress/result (if any) 14.5px leading 1.5 #A8A8AD mt10, markdown (streaming while running).
- **child_bot**: button card w min(340, 90%), same card style: name + pill ("bot" green / "deleted" red); text 14.5px #A8A8AD mt8: deleted → "Removed this bot, including its chat, computer, and memory." else `title || "Opened its own thread. Tap to switch."`; click → navigate to that bot (disabled when deleted, opacity 0.6).
- **text + role user**: right bubble max-w 70%, rounded 20 bg #F1F1EF px18 py12, 15.5px leading 1.45 #1A1A1A (plain text).
- **text + role bot**: left bubble max-w 74%, rounded 20 bg #1A1A1D px18 py12, 15.5px leading 1.5 #DFDFE2, markdown.
- **card**: left bubble rounded 20 bg #1A1A1D px20 py16, column gap 8: per line — "✓" #30A24B + k (semibold white) + "→" #85858A + v, 15px.
- **ask**: max-w 74%, rounded 20 border #242428 bg #141417 px20 py17: text 15.5px leading 1.5 #ECECEE (markdown); optional detail in `<pre>` style (rounded 12 bg #0E0E10 px14 py12, mono 12.5px leading 1.7 #85858A); buttons row mt14 gap 8: "Send it" (cream rounded 11 px17 py8, 14.5px medium) → answerAsk; "Edit first" (border #26262A, text #C9C9CE) — no action (rakazo has none).
- **computer**: card w340 rounded 18 border #232326 bg #17171A px18 py16: "Computer" 15px medium + state pill (green style); text 14.5px #A8A8AD mt10 markdown.
- (choice/connect blocks exist in the model but rakazo's Shell doesn't render them — skip rendering, keep the cases.)

### 5.13 RightPanelView.swift (w384, bg #0A0A0B)
Scroll content px20 py17. Header row (shown for computer/settings panels only, mb16): left = `computer.state ?? bot.status` 13.5px #85858A; right = "⚙" (→ settings panel) and "✕" (close panel), ~15px default text color.

**computer panel:** screen area aspect 16:10 rounded 14 bg #0E0E10 (relative; a full-area invisible button opens the computer overlay). Content by state: user has control → "Open in full window" centered 13–14px #6C6C70; kind desktop → "This bot runs on this computer, not a Linux desktop. Shell and files use your home folder."; running (no URL) → "{name}'s screen"; booting/overlay-booting → "Booting live desktop…"; suspended → "Computer is asleep — take control to wake it"; error → "Computer failed to boot"; stopped → "Computer is stopped". Below (mt12, space-between): status text 13.5px #85858A ("You have control" / "Asleep" / "{name}'s screen") + Take control / Release (outline sm). Then "Routines" label 14px #85858A (mt30 mb12). Routine rows: "◷" #E65707 + name 14.5px #ECECEE (flex-1, left) + `Cron.formatCron(routine.cron)` 13px #6C6C70; hover bg #121214; click → load into routine editor (preset via `Cron.preset(fromCron:)`) and open `routine` panel. "Run now" row (14.5px #7A7A80, px10 py10) → runs first routine (or opens empty editor if none). "+ New routine" row same style → empty editor.

**create panel:** header "New bot" 13.5px #85858A + "✕". Name (mt24, placeholder "Name this bot"), Title ("Describe what this bot does"), Description textarea rows 4 ("What this bot is for"); "Create" cream rounded 11 px16 py8, disabled until name. Creates bot (instructions = description), selects it, closes panel.

**settings panel:** avatar 64 centered; Name input (mt24), Title, Description textarea rows 4; column mt20 gap12: "Save" (cream rounded 11 px16 py8) → updateBot(name, title, description, instructions: description); "Export" (14px #85858A) → NSSavePanel JSON manifest; "Delete bot" (14px #E65707) → replaces with confirm box: rounded 11 border #3A1F14 bg #1A100C px14 py12 — text 13.5px leading 1.45 #C9C9CE: "This permanently deletes {name}, including thread, computer, memory, and routines. Bots it created stay in your list."; row mt12: "Cancel" (14px #85858A) + "Delete" (bg #E65707 rounded 11 px14 py6, 14px #F1F1EF; while deleting → "Deleting…"); error text below 13px #E65707.

**routine panel:** header row: "‹" (→ computer panel, #9A9AA0) / "Routine" 15.5px medium #F1F1F2 centered / "✕" (#6C6C70). Name input (label 14px #85858A); Instruction textarea rows 4 ("Instruction"); "When to run" label + RoutineScheduleView; "Save" cream rounded 11 px16 py8 mt20 → createRoutine (name || "Routine", prompt || "Check in.", cron from preset, timezone UTC, active true, notify true) → back to computer panel.

### 5.14 RoutineScheduleView.swift
Container rounded 13 border #26262A p12. Row 1: clock icon (circle r9 + hands, 17px stroke #C9C9CE) + lead text 14.5px #ECECEE + detail 14.5px #85858A (from `Cron.describe`). Row 2 (mt10, rounded 11 bg #16161A px10 py10, flex-wrap gap 8, 14px #7A7A80): freq chip-select (all `Cron.freqs`); if Interval → "every" + n chip-select (`Cron.numbers`, plus current value if custom) + unit chip-select (minutes/hours/days); if freq in [Every day, Weekdays, Every week, Every month] → "at" + time chip-select (`Cron.times`, plus current if custom); if Advanced → cron text input (mono 13.5px, bg #24242A rounded 8 px10 py6, placeholder "*/3 * * * *"). Selecting "Advanced" keeps the current cron value (rakazo behavior: `patch({ freq, cron: cronFromPreset(value) })`).

### 5.15 PluginsOverlayView.swift
Full overlay bg rgba(4,4,5,0.62) p40, centered card 1080×760 (max-w full), rounded 26 border #232326 bg #141416, shadow 0 40 90 rgba(0,0,0,.55). Header (px32 pt28): "Plugins" 24px medium #F1F1F2 + sub 13.5px #7A7A80 ("Loading catalog…" or "{n} apps"); "✕" right (#85858A). Search (px32 pt16): rounded 13 border #26262A bg #101012 px16 py12, 15px #ECECEE, placeholder "Search apps" (filters name+slug). List (flex-1 scroll px32 py24): error 13px #C94244; rows rounded 13 px12 py10 gap 16: logo square 42 rounded 12 bg #2C2C30 (initial, semibold); name 15.5px medium #ECECEE + slug 13.5px #7A7A80 (append " · no auth" when applicable); right: pill button Connect/Revoke (rounded-full bg #1B1B1F, 13px; pending → "Connecting…"/"Revoking…", disabled).

### 5.16 HostComputerPromptView.swift
Overlay bg rgba(5,5,6,0.8) centered; card 440 rounded 20 border #26262A bg #121214 p24. h2 22px medium #F1F1F2 "Where should bots run?"; text mt8 14px leading relaxed #85858A: "Docker is the default: each bot gets an isolated Linux desktop with a browser. macOS will not ask for extra permission if you let bots run on this Mac — they run as you." (native app ⇒ always the macOS wording). Error 13px #E65707. Buttons (mt20, column gap 8): "Docker (recommended)" cream rounded 11 px20 py10; "Use this Mac" outline (border #26262A, text #ECECEE). Footnote mt12 12px leading relaxed #6C6C70: "This Mac runs shell commands with your account, including files in your home folder. Do not turn it on for a shared or public server." Choosing persists `deployment.computerHost` and closes.

## 6. Remaining work — Tests (Tests/GrizzyBotCoreTests/)

Use Swift Testing (`import Testing`, `@Suite`/`@Test`). Store tests: instantiate `AppStore` with a temp data dir (add an init parameter or env override for the persistence path so tests don't touch real Application Support).

- **CronTests** — port of rakazo `cron.test.ts`: fromPreset: Every day 9AM→"0 9 * * *", Weekdays 8AM→"0 8 * * 1-5", Every week 9AM→"0 9 * * 1", Every month noon→"0 12 1 * *", Every hour→"0 * * * *", midnight→"0 0 * * *", 3PM→"0 15 * * *"; intervals: 15min→"*/15 * * * *", 2h→"0 */2 * * *", 3d→"0 0 */3 * *"; Advanced passthrough + empty→"*/3 * * * *". presetFromCron: "0 9 * * 1"→Every week; round-trip freq for all presets; "0 9 * * 0"→Advanced; "30 14 15 * *"→Advanced. formatCron("*/15 * * * *")=="Every 15 minutes"; describe(Every hour)==("Every hour","").
- **ScriptedRuntimeTests** — each branch: sign-in resume text; "sign in"→takeover; "spawn a bot named Scout"→spawnBot(Scout); no name→Helper/Scout defaults; "delete the bot named X"; "use a subagent"→subagent; "crm"→destinationWrite; "write a note that says Hello."→writeFile content "Hello\n"; "remember X"→remember; default reply contains "on it." and "done. i handled:".
- **StoreTests** — signUp validation (short password, duplicate email exact message); signIn wrong password → "Invalid login credentials"; bot create color cycling (1st #3EC5A8, 2nd #F5A03C); updateBot; deleteBot keeps children; send() → run completes, bot message present, preview updated, usage recorded (12/40); stopRun cancels; routine create + runNow appends meta message; computer boot → running after delay, takeControl/release flips controlHolder; plugins connect/revoke; weeklySummary math.

## 7. Remaining work — Packaging & docs

- `Scripts/make-app.sh`: `swift build -c release`; assemble `GrizzyBot.app/Contents/{MacOS,Resources}`; Info.plist with CFBundleIdentifier `com.grizzybot.app`, CFBundleName GrizzyBot, CFBundleExecutable GrizzyBot, LSMinimumSystemVersion 15.0, NSPrincipalClass NSApplication, CFBundlePackageType APPL, NSHighResolutionCapable true; copy binary into MacOS/. Then `open GrizzyBot.app`.
- `README.md`: what it is, build (`swift build`), test (`swift test`), run app (script or `open .build/release/...` via bundle), feature list mirroring rakazo.
- `.gitignore`: `.build/`, `GrizzyBot.app`, `*.xcodeproj` (if any), `DerivedData/`.

## 8. Reference: rakazo source files (only if the repo is still on this machine)

Repo root: `/Volumes/Storage/Projects/GrokBot/rakazo` (sibling of this project). Key files already fully analyzed:
- `apps/web/src/App.tsx` — routing (welcome/sign-in/sign-up/onboarding/app)
- `apps/web/src/pages/Shell.tsx` (47KB — the main screen, all panels + message blocks)
- `apps/web/src/pages/{Welcome,Auth,Onboarding,PluginsOverlay,RoutineSchedule,HostComputerPrompt,WindowChrome}.tsx`
- `packages/ui-web/src/{bot-avatar.tsx,button.tsx}` — avatar geometry + button variants
- `packages/chat-ui/src/markdown.web.tsx` — markdown rendering approach
- `packages/core/src/cron.ts` — cron logic (ported)
- `packages/contracts/src/{domain.ts,events.ts,ids.ts}` — data models + BOT_COLORS (ported)
- `packages/adapters/src/{pi-models.ts,pi-oauth.ts,scripted-runtime.ts}` — catalog + scripted behavior (ported)
- `packages/db/src/repos.ts` — bot color cycling, createBot side effects

Puzzle icon SVG path (sidebar Plugins button, 24×24 viewBox, stroke 1.7):
`M4 7h3a1 1 0 0 0 1-1 1.5 1.5 0 1 1 3 0 1 1 0 0 0 1 1h3v3a1 1 0 0 0 1 1 1.5 1.5 0 1 1 0 3 1 1 0 0 0-1 1v3h-3a1 1 0 0 0-1 1 1.5 1.5 0 1 1-3 0 1 1 0 0 0-1-1H4v-3a1 1 0 0 0-1-1 1.5 1.5 0 1 1 0-3 1 1 0 0 0 1-1z`
(Easiest in SwiftUI: a tiny SVG-path parser for M/h/v/a/z, or hand-draw with `Path`.)

## 9. Pitfalls already hit (Swift 6.3 specifics — don't repeat)

1. **Array subscripts are non-optional in Swift 6** — `parts[0] ?? "*"` warns; use plain subscripts after a count guard.
2. **`||` is Bool-only** — no string coalescing; use `isEmpty ? fallback : value`.
3. **Extended regex literals with flags (`/.../i`) fail to parse** in some positions (the flag gets dropped → "consecutive statements" error). Workaround that works: standalone `let pattern = /[sS]ays?\s+(?<said>.+)$/` (no flags; fold case-insensitivity into the character class) or `try! Regex("...")` for string patterns.
4. **String-based `Regex("...")` yields `Regex<AnyRegexOutput>`** — you cannot access `.1` or named members on it. Use **extended regex literals with named captures** (`/(?<bot>...)/`) which produce typed tuple outputs, or NSRegularExpression.
5. Pipe exit codes: `swift build | tail` hides failures — check `$?` of the real command (e.g. `swift build > log 2>&1; echo $?`).
6. Keep everything the store touches on `@MainActor`; models must be `Sendable` (they are).

## 10. Definition of done / verification checklist

- [x] `swift build` → exit 0, no errors (warnings acceptable but fix trivial ones)
- [x] `swift test` → all suites pass (Cron, ScriptedRuntime, Store)
- [x] All screens exist and match §5 specs: Welcome, Auth (in+up), Onboarding (model/bot/2 questions/done), Shell (sidebar, chat with all 8 rendered block types + working… pulse, input bar), right panels (computer/create/settings/routine), RoutineSchedule widget, Plugins overlay, HostComputerPrompt, booting overlay, computer full-window
- [x] Full loop works in the running app: sign up → connect model (or skip) → create bot → answer questions → chat (default reply, spawn a bot named X, use a subagent, remember X, write a note that says …, sign in) → computer panel (boot, take control/release, routines: create with schedule picker, run now) → plugins connect/revoke → settings save/export/delete (with confirm; children survive) → user menu weekly usage + log out
- [x] `Scripts/make-app.sh` produces a launchable GrizzyBot.app; app opens without crashing (launch, wait ~5s, confirm process alive, quit)
- [x] README.md written
