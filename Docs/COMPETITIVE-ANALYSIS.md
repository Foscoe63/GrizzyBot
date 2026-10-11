# GrizzyBot — Competitive Deep Dive (Oct 2026)

Compared: **Grok Bot** (xAI), **OpenMausBot**, **Rakazo**, **Codync**, **OpenClaw** (+ its clones), **Hermes Agent**, plus Goose, DeerFlow, nanobot, IronClaw, ZeroClaw, NanoClaw, QwenPaw, Moltis, AnythingLLM, browser-use, OpenHands.
GrizzyBot baseline = v0.8.1, `README.md` + a source spot-check of `Sources/GrizzyBotCore`.

> Scope notes. Grok Bot is closed source: everything below comes from its launch post and 0.59–0.68 changelog, not code. I read the Rakazo and OpenMausBot READMEs in full, but not their source. "Openbot" is ambiguous; I treated it as OpenClaw/OpenMausBot. Source-level claims about GrizzyBot are from grep, not a full read — verify before building.

---

## Implementation status (v0.9.0)

Built from the recommendations below: run queue with steer/collect/follow-up (#2), webhooks and heartbeat (#1), cron continuity (#3), `/context` `/goal` `/plan` `/compact` `/usage` (#16), `search_sessions` (#4), skill scanner (#6), team packages and an OpenClaw/Hermes workspace importer (#12, #26), checkpoints with `/rollback` (#15), hash-chained audit (#21), and **Telegram** in place of the iOS companion (#9, #10 — chosen by the owner). Not built yet: secure forms (#13/#14), draft cards (#24), the learning loop (#5), teach-by-demonstration (#7), the proactive primary bot (#8), an MCP control-plane server (#11), ACP, a router model, OpenAPI tools, voice calls.

---

## 1. Where GrizzyBot already leads

Don't give these up chasing parity.

| Strength | Why it matters |
|---|---|
| Truly native Swift/SwiftUI, no Electron/Docker/Node | Every rival is TypeScript/Electron/Python. Only Codync's Mac app and Goose are native. |
| In-process **Local MLX** | No rival runs models inside the app. Real privacy and offline story. |
| **CEL action policy** that hit-tests the screenshot outline, MCP grant matrix, knowledge ACLs, owner/operator roles, 2,000-event audit | Stronger than OpenMausBot's allow/deny cards, Hermes' approvals, or Grok Bot's "Always allow" rules. Closest peer is QwenPaw's Tool Guard / File Guard. |
| `sandbox-exec` shell with credential-dir read denials, process-group kill | OpenClaw ships with *no* sandbox by default; NanoClaw/Moltis need Docker. |
| Artifacts (React/Mermaid/SVG/HTML, versioned, network-closed frame) | Only Claude Desktop does this. Grok Bot just added slide decks. |
| Keychain secrets, PII filter, redacted exports, diagnostic scrubber | Matches or beats everyone. |
| Hybrid BM25+salience memory, pins, secret refusal | Comparable to Hermes/OpenClaw Markdown memory. |
| Capability discovery (BM25 over skills + MCP), per-bot skill switches | Same idea as AnythingLLM's "intelligent skill selection" to cut tool-token overhead. |

---

## 2. Competitor snapshot

**Grok Bot (xAI, launched 2026-08-11, now v0.68.1).** Cloud computer per team, sign-in to tools, routines, desktop + iOS, Slack. Its edge is *product polish*: "show a bot how it's done → saved as a routine", primary bot that proactively offers work, Secure Form window for logins, approval cards that quote the instruction, Team Bots published to a team (own memory per user), 1920×1200 bot screen, slide decks → PPTX/Google Slides, editable email draft cards, Library tab of everything a bot shared, voice calls, cross-device approval.

**OpenMausBot.** Telegram-style roster of bots. Drivers run local `claude` / `codex` / `grok` CLIs (BYO subscription). Permission broker, Composio apps, Boat cloud VMs or Cua-driven host control, channels (Work/Personal/project contexts) with responder rules, a fast "decision model" that picks which bot answers an un-mentioned message, **team packages as one Markdown file** (YAML frontmatter, imported paused/off, no credentials), team sharing/presets/org library, **webhook triggers on a dedicated 127.0.0.1 receiver** (bearer secret shown once), interval routines that skip when the previous run is still active, **stdio MCP server exposing a bounded team control plane**, voice calls with multiple TTS engines, desktop-to-desktop companion over Tailscale.

**Rakazo (Apache-2.0).** Pi agent runtime, web + Electron + Expo mobile. Team Computer (shared, `bots/<id>/` + `shared/`) vs Private Computer, pluggable computer providers (Docker, E2B, Daytona, Box, local), Composio **or Pipedream** plus remote MCP and **OpenAPI tool sources**, voice with four TTS vendors, takeover *request* mechanism, E2B checkpoint/restore of workspace + browser profile, 98 contributors in weeks.

**Codync.** Wraps any ACP agent (Claude Code, Codex, Cursor, Gemini, Copilot, OpenCode…) as a persistent bot; iPhone app with push, Live Activities, widgets, remote screen, voice calls; end-to-end-encrypted Cloudflare relay with a 24h offline mailbox; `team` MCP server with `ask_bot`; reply threads that fork a message into its own agent session; `codync-host tui`.

**OpenClaw (373k stars).** Gateway = single control plane (typed WS req/res/event). **Lane-aware FIFO queue: one run per session, queue modes `collect` / `followup` / `steer`.** Five wake sources: messages, **heartbeat (30 min, `HEARTBEAT_OK` = silent)**, cron, webhooks, hooks. Workspace files injected each session (`SOUL.md`, `AGENTS.md`, `HEARTBEAT.md`…). 20+ chat channels, DM pairing, ClawHub registry, `openclaw security audit`. **Cautionary tale:** hundreds of malicious ClawHub skills (reports range 341 → 820+), gateway bound to 0.0.0.0, no default sandbox.

**Hermes Agent (Nous, MIT).** Closed learning loop: `/learn` creates skills from a finished task, skills self-refine, periodic memory nudges, FTS5 search over *all past sessions* with LLM summarisation, Honcho user model, `/journey` review. **Cron `--continuity` feeds the previous run's output into the next.** Steerable subagents (mid-run steering, stop while keeping partial results), `hermes peer`, `/goal`, `/context` breakdown, `/rollback` filesystem checkpoints, `/diff`, `/init`, `/focus`, signed webhooks, secret redaction on export, protected instruction-file writes, `claw migrate` importer.

**Others worth stealing from.** ZeroClaw: cryptographic **tool receipts**, supervised risk tiers, event-driven SOPs. IronClaw: WASM-sandboxed tools, host-side secret injection (the model never sees the secret). NanoClaw: credential vault injecting per-agent. Goose: ACP + 70 MCP extensions, recipes. DeerFlow: sub-agents with isolated context + scoped tools + termination conditions, Langfuse tracing. QwenPaw: Skill Scanner. Moltis: importers, passkey auth. AnythingLLM: document workspaces.

---

## 3. Gap matrix

Legend: ✅ have · 🟡 partial · ❌ missing. "Seen in" lists who does it best.

| # | Capability | GrizzyBot | Seen in |
|---|---|---|---|
| 1 | Event-driven wake-ups (webhooks, heartbeat turns) | ❌ (cron only; "heartbeat" in code is a computer keep-alive) | OpenClaw, OpenMausBot, Hermes |
| 2 | Message while bot is busy: queue / steer / collect | ❌ no queue modes found | OpenClaw, Grok Bot |
| 3 | Cron continuity (previous output → next run) | ❌ | Hermes |
| 4 | Cross-session search tool the agent can call | 🟡 UI `searchChats` only; no agent tool | Hermes |
| 5 | Learned skills (`/learn`, self-refine, nudges) | 🟡 `skill-creator` skill is manual | Hermes |
| 6 | Skill supply-chain scan / quarantine on import | ❌ (imported skills start *off*, which helps) | QwenPaw, OpenClaw post-mortem |
| 7 | Teach-by-demonstration → routine | ❌ | Grok Bot |
| 8 | Proactive primary bot | 🟡 Chief of Staff exists but "does not auto-delegate" | Grok Bot |
| 9 | Remote / mobile access (iOS app, push, relay) | ❌ | Grok Bot, Codync, Rakazo, OpenMausBot |
| 10 | Messaging channels (iMessage, Telegram, Slack, Discord) | ❌ (Slack is a plugin, not a channel) | OpenClaw, Hermes, ZeroClaw |
| 11 | Expose GrizzyBot *as* an MCP server (team control plane) | ❌ (has OpenAI gateway only) | OpenMausBot, Hermes, Codync |
| 12 | Team package: export/import whole team as one file | ❌ | OpenMausBot, Grok Bot |
| 13 | Secure Form / credential hand-off without the model seeing it | ❌ (only `request_takeover`) | Grok Bot, IronClaw |
| 14 | Host-side secret injection into tools | ❌ | IronClaw, NanoClaw |
| 15 | Checkpoints + `/rollback` for file edits | ❌ | Hermes |
| 16 | `/context` token breakdown, `/goal`, `/plan`, `/focus` | ❌ (token stats exist) | Hermes, nanobot |
| 17 | Steerable / stoppable subagents, parallel with live transcript | 🟡 recent commit added helper pause/failure, parallel helpers | Hermes, DeerFlow |
| 18 | Reply threads (fork a message to its own session) | 🟡 branching exists | Codync |
| 19 | Bring-your-own CLI agents via ACP (Claude Code, Codex…) | ❌ | Codync, Goose, OpenMausBot |
| 20 | Fast router picks which bot answers in a room | ❌ (@mention only) | OpenMausBot |
| 21 | Tool receipts (tamper-evident audit) | 🟡 audit log, not signed/chained | ZeroClaw |
| 22 | OpenAPI/remote tool sources, Pipedream | ❌ (MCP + Composio) | Rakazo |
| 23 | Voice *calls* (hands-free, spoken approvals), wake word | 🟡 dictation + TTS only | Grok Bot, OpenMausBot, Hermes |
| 24 | Draft cards for outbound email/Slack with Send button | ❌ (Gmail writes send directly) | Grok Bot |
| 25 | Library of files/links a bot shared | 🟡 artifacts panel | Grok Bot |
| 26 | Importers (OpenClaw/Hermes) | ❌ | Hermes, Moltis, NanoClaw |
| 27 | Observability / tracing export | 🟡 audit + diagnostics | DeerFlow |
| 28 | Cross-platform | ❌ macOS only (by design) | all others |
| 29 | Native Mac integrations (Siri/App Intents, Spotlight, Shortcuts-as-trigger) | 🟡 Shortcuts tools only | none — open field |

---

## 4. Recommendations

Ranked by value ÷ effort, with a one-line "how" anchored in the existing code.

### Tier 1 — high value, fits the architecture, do first

1. **Triggers: webhooks + heartbeat.** Add a `RoutineTrigger` alongside `Cron.swift`/`RoutineTickPlanner.swift`: (a) loopback-only webhook receiver on its own port (bearer secret shown once, `/health` + `/hooks/<id>` only — copy OpenMausBot's design; `LocalOpenAIGateway.swift` already has a listener to reuse), (b) per-bot `HEARTBEAT.md` checklist run every N minutes where `HEARTBEAT_OK` suppresses output. Reuse the existing 2-concurrent-run cap and backoff. *Closes #1 and unlocks most "proactive" use cases.*
2. **Run queue with modes.** One active run per bot/thread; incoming messages `collect` (default), `followup`, or `steer` (inject at the next tool boundary in `AgentLoop`). Also skip an interval routine if its previous run is still active. *Closes #2; this is the single biggest "feels like a teammate" fix.*
3. **Cron continuity.** Per-routine toggle that injects the last run's final output (bounded) into the prompt. Tiny change in `AppStore+Routines.swift`, large payoff for monitors and digests. *#3.*
4. **`search_sessions` tool.** Index chat transcripts in SQLite FTS5 (GRDB-free is fine via `sqlite3`), expose as an agent tool with optional LLM summary, scoped to the bot (never siblings, same rule as `search_memory`). *#4.*
5. **Skill safety scanner.** On `import_skills`: static checks (shell pipes to `curl|sh`, base64 blobs, `allowed-tools` escalation, references to `~/.ssh`/Keychain, hidden-Unicode/prompt-injection phrases), a risk badge in the Skills panel, and keep "off by default". OpenClaw's ClawHub incident makes this table stakes before any registry/sharing feature. *#6.*
6. **Team package import/export.** One Markdown file with YAML frontmatter: bots (instructions, skills, tool toggles), rooms, routines (imported **paused**), roster/Chief of Staff, connector slots. Never include credentials, chats, memory, or computer grants — OpenMausBot's rules are right. Add a review screen. *#12; also the foundation for sharing and onboarding.*
7. **Slash commands from Hermes:** `/context` (system/tools/skills/MCP/memory/history/free breakdown — you already count tokens), `/goal` (persistent objective re-checked each turn), `/plan` (write plan, don't execute), `/focus`, `/compact`. Extend `SlashCommand.swift`. *#16.*

### Tier 2 — strategic, bigger

8. **Expose GrizzyBot as an MCP server.** Stdio server with a *bounded* control plane: list bots/rooms, read/search transcripts, send message, wait for completion, interrupt, switch model. Explicitly exclude approvals, deletion, credentials, computer lifecycle (OpenMausBot's boundary). Lets Claude Desktop/Cursor/Claude Code drive your bots. *#11.*
9. **Secure Form + secret injection.** A `request_secret` tool that opens a native form; the value goes straight to Keychain/into the target field and the transcript records only a char count (you already log secrets that way). Longer term, IronClaw-style host-side injection so plugin tokens never enter model context. *#13/#14.*
10. **Checkpoints + rollback.** Snapshot files a run is about to modify (copy-on-write under the bot home), `/rollback` lists and restores. Cheap safety net given the `edit_file`/shell write surface. *#15.*
11. **Learning loop (Hermes-style), gated.** After a run with ≥N tool steps and success, offer "Save as skill?"; `/learn <task>`; periodic memory-curation nudge. Keep human approval on write — skills are privileged context. *#5.*
12. **Draft cards for outbound writes.** Email/Slack/calendar writes render as an editable card with Send; "Disable drafts for this bot" like Grok Bot. Fits `present_component` + CEL (`mcp.effect == "write"`). *#24.*
13. **Teach-by-demonstration.** Record a supervised computer-use session (screenshots + clicks + your corrections) and have the model synthesise a routine/skill. Grok Bot's headline feature; heavy but differentiating, and your screenshot-outline targets make it more reliable than pixel replay. *#7.*
14. **Proactive primary bot.** Let the Chief of Staff run a low-frequency scan (calendar, inbox, watchers) and *offer* tasks as a card — never act unprompted. Pairs with #1. *#8.*

### Tier 3 — ecosystem / reach

15. **iOS companion + relay** (Codync is the model: QR pairing, E2E-encrypted relay, push for approvals, Live Activities). Biggest user-visible gap vs. Grok Bot, but a large separate project. Cheaper stepping stones: Tailscale-friendly authenticated mode for the existing gateway, and approval notifications via `UNUserNotificationCenter` action buttons.
16. **One messaging channel first — iMessage or Telegram** — with OpenClaw-style DM pairing codes (expire in 1h, capped pending). Don't build 20.
17. **ACP client** so a bot can be backed by Claude Code/Codex/Gemini CLIs using the user's existing login (Codync, Goose, OpenMausBot). Complements Local MLX and cloud keys.
18. **Router model for rooms** (cheap/local model picks the responder for un-mentioned messages; MLX is ideal here). *#20.*
19. **OpenAPI tool source** (import a spec → tools, gated by the grant matrix) and Pipedream. *#22.*
20. **Voice calls**: continuous listen/speak loop with spoken approvals; optional wake word. *#23.*
21. **Importers** for OpenClaw/Hermes workspaces (`SOUL.md`, `MEMORY.md`, skills, cron). Cheap acquisition path. *#26.*
22. **Hash-chained audit / tool receipts** and OTLP/Langfuse export. *#21, #27.*
23. **Mac-only wins nobody has:** App Intents/Siri ("Ask Researcher…"), Spotlight, Shortcuts *as a trigger* (not just a tool), Focus-mode-aware notifications, Share extension. Lean into being the best *Mac* citizen.

### Things not to copy
- Docker/E2B/cloud VM computers — contradicts the local-first identity. If ever wanted, expose it as an optional provider behind the existing `ComputerRuntime` seam.
- Open skill registry without signing/scanning (ClawHub).
- Binding any listener to 0.0.0.0 by default; keep loopback + token (OpenClaw's mistake).
- 20-channel sprawl; Electron/Node rewrite.
- Grok Bot's "Typing / no longer opens skills menu" — keep `/`.

---

## 5. Suggested roadmap

| Release | Theme | Items |
|---|---|---|
| **0.9** | Always-on | Run queue + steer (#2), webhooks + heartbeat (#1), cron continuity (#3), `/context` `/goal` `/plan` (#7) |
| **0.10** | Memory & safety | `search_sessions` FTS5 (#4), skill scanner (#5), checkpoints/rollback (#10), secure form (#9) |
| **0.11** | Teams | Team packages (#6), draft cards (#12), learning loop (#11), MCP control-plane server (#8) |
| **1.0** | Reach | Proactive primary bot (#14), iMessage/Telegram channel (#16), notification-actions → iOS companion groundwork (#15) |
| **Later** | | ACP client, router model, OpenAPI tools, voice calls, demonstration recording, importers |

---

## 6. Sources

- Grok Bot: [launch post](https://x.ai/news/introducing-grok-bot), [changelog](https://x.ai/changelog/bot), [Composio guide](https://composio.dev/content/guide-to-frok-bot), [Unite.AI](https://www.unite.ai/xai-launches-grok-bot-always-on-ai-teammates-with-their-own-cloud-computers/)
- OpenMausBot: [GitHub](https://github.com/milind-soni/OpenMausBot), [mausbot.com](https://mausbot.com/)
- Rakazo: [GitHub](https://github.com/elie222/rakazo), [ScriptByAI review](https://www.scriptbyai.com/rakazo-grok-bot-alternative/)
- Codync: [ScriptByAI review](https://www.scriptbyai.com/codync-grok-bot-muse-alternative/)
- OpenClaw: [architecture part 1](https://theagentstack.substack.com/p/openclaw-architecture-part-1-control), [security / malicious skills](https://thehackernews.com/2026/02/openclaw-integrates-virustotal-scanning.html), [features overview](https://blog.openreplay.com/openclaw-open-source-ai-assistant/)
- Hermes Agent: [ScriptByAI review](https://www.scriptbyai.com/hermes-agent/), [docs](https://hermes-agent.nousresearch.com/docs)
- Alternatives: [7 best OpenClaw alternatives](https://www.scriptbyai.com/best-openclaw-alternatives/), [10 best open-source agents](https://www.scriptbyai.com/best-ai-agents/)

---

# Round 2 (Oct 11, 2026) — after 0.9.0

Baseline: v0.9.0 (`ba06c8f`). Re-checked Grok Bot's changelog through **0.68.1**, plus Meta Muse / OpenAI Dots, OpenClaw's memory and security docs, Hermes (curator, kanban), ZeroClaw, IronClaw, NanoClaw, Goose. Source claims about GrizzyBot below were grep-verified against `Sources/GrizzyBotCore`; competitor claims come from READMEs/docs/blogs, not their code.

## New since round 1

| Source | What's new |
|---|---|
| **Grok Bot 0.59–0.68** | **Auto-review cards** with "Always allow" that become named *Custom Rules*, editable from the card; approval cards quote the instruction and name the bot; **a busy bot answers you before its queued background updates**; hung-step watchdog (Stop or new message frees a stuck bot in ~30s); **reconnect card** when an OAuth token expires instead of retrying; **Library tab** of everything a bot shared; word-synced voice-memo transcripts; per-bot accent colour; quote-selection-into-prompt (⌘L); **Disable drafts for this bot**; automatic **model routing** (cheap model for easy turns, strong model for hard ones; no visibility yet, a complaint); 1Password as the login source before falling back to a secure form; per-bot inbox (rolling out). |
| **Meta Muse / OpenAI Dots** | Memory the user can **inspect and edit** is the differentiator reviewers cite (Dots can't; disconnecting a plugin doesn't delete what was learned). |
| **OpenClaw** | **Pre-compaction memory flush** (silent turn: "save what matters before it's summarised"), background "dreaming" consolidation, **memory writes from network-tainted turns are quarantined / marked untrusted**, MEMORY.md compaction that preserves user-authored headings, forgotten content must not resurface via retries or consolidation, `security audit` command, session keys with a secure-DM scope. |
| **Hermes** | **Curator**: background pass that consolidates/archives agent-made skills, never deletes (archive + restore + pin + backup/rollback), tracks per-skill usage, skips bundled skills. **Kanban**: durable SQLite board with heartbeats, reclaim, retry budgets, circuit breaker, "budget warning at 90% of iterations". `environments:` frontmatter hides context-specific skills from the index. |
| **IronClaw** | Host-side credential injection plus **bidirectional leak scanning** (outbound requests and inbound responses), prompt-injection detection with Block/Warn/Review/Sanitize tiers, tool output wrapped before it reaches the model, per-tool rate limits, RRF hybrid search. |
| **ZeroClaw** | Seatbelt on macOS (GrizzyBot already has), **provider fallback chains**, **streaming → non-streaming retry**, resumable SOPs with approval gates, `launchctl` service (GrizzyBot already has via SMAppService). |
| **NanoClaw** | Per-agent credential gateway; **script gates** (a cheap script decides whether to wake the agent at all); per-agent templates with no secrets. |
| **Goose** | Recipes (parameterised, shareable task definitions), custom distributions. |

## Re-verified GrizzyBot gaps (grep on 0.9.0)

| Gap | Evidence |
|---|---|
| No untrusted-content boundary for **web pages, MCP/plugin results, emails** | "untrusted" appears only for webhook payloads (`RoutineEvents.swift:68`) and the ai-memory handoff (`AgentLoop.swift:502`). Tool results enter context raw. |
| Memory can be poisoned by injected content | `remember` has secret refusal but no provenance/taint; a bot that just read a web page can write to `MEMORY.md`/`SHARED.md`, which every later turn trusts. |
| No pre-compaction memory flush | `AgentLoop.compact` / `/compact` summarise; no "save facts first" turn. |
| No provider fallback / non-streaming retry | `LLMClient` has no failover chain; only 429/5xx retry. |
| No model routing | A bot has one model; no cheap-for-easy / strong-for-hard policy. |
| Always-allow is per tool name | `alwaysAllowTools: [String]` — not scoped by host, path or argument pattern, and not editable as a rule from the approval card. |
| Skills never refine themselves | Scanner exists; no curator, usage counts, or `/learn`. |
| No OS notifications with actions | `UNUserNotification` absent. Approvals only work while the window is in view. |
| No App Intents / Spotlight / Siri / Shortcuts-as-trigger | Not present. Nobody else has this either. |
| No tracing export | No OTLP. |

## Recommendations, ranked

### Tier 1 — close real exposures first
1. **Untrusted-content envelope.** Wrap `web_search`, MCP, plugin and email results in a delimited block ("data, not instructions") and strip/flag instruction-shaped text; extend the existing `SkillScanner` phrase list to runtime content. Cheapest large safety win.
2. **Memory provenance + taint.** Stamp each fact with source (user / web / tool / routine). A turn that ingested untrusted content cannot write `## Pin` or `SHARED.md` without approval; surface provenance in the memory editor. (OpenClaw 2026.8 does this.)
3. **Pre-compaction memory flush.** One silent turn before `compact` that offers the bot a chance to `remember`. Small change in the compaction path; large effect on long threads.
4. **Scoped Always-allow → Custom Rules.** Turn `alwaysAllowTools` into rules (tool + host/path/arg pattern + bot), created from the approval card, listed and editable in Settings. Reuse CEL. Matches Grok Bot's Custom Rules and keeps your governance lead.
5. **Provider fallback chain + streaming→non-streaming retry** in `LLMClient`; per-bot "if this fails, try…". Local MLX as the last link makes an offline story no rival has.
6. **Hung-step watchdog beyond the stream**: 30s unblock on Stop for stuck tools/computer actions (the shell runner already kills process groups; extend to MCP/computer calls).

### Tier 2 — product depth
7. **Model routing.** Rule-based first (short/simple turn, no tools → small/local model), with the chosen model *shown in the tool card* (fixes Grok Bot's main complaint).
8. **Skill curator + usage counts.** Track skill loads; `/learn` proposes a skill after a ≥N-step success; a weekly curator pass proposes merges and **archives, never deletes**; pinned and bundled skills are untouchable. Always human-approved writes.
9. **Script gates for routines.** A routine can run a cheap shell/CEL check first and skip the model call when nothing changed. Directly cuts cost for heartbeats.
10. **Actionable macOS notifications** (Approve/Deny/Open, Focus-aware) via `UNUserNotificationCenter`. Makes approvals work when the app is backgrounded and is the groundwork for any later iPhone companion.
11. **Library view** (everything a bot shared: artifacts, files, links, by day). You already hold the data.
12. **Reconnect cards** for expired OAuth/MCP auth instead of retry loops; **draft cards** for outbound email/Slack with a per-bot "disable drafts" toggle.
13. **Memory UI parity with Muse**: an inspectable timeline of what each bot learned, with per-item delete that survives consolidation.

### Tier 3 — differentiate as the best Mac citizen
14. App Intents ("Ask Researcher…"), Spotlight, Shortcuts *as a trigger*, Share extension.
15. Recipes: parameterised routine/team templates (builds on Team packages).
16. MCP control-plane server (stdio) with the bounded surface from round 1.
17. OTLP/Langfuse export from the hash-chained audit.
18. Secure form / 1Password-style credential handoff (Keychain-backed), host-side secret injection into plugin calls with request/response leak scanning.

### Still not worth copying
Docker/cloud VMs, 20-channel sprawl, an open registry without signing, 0.0.0.0 listeners, Kanban-as-separate-OS-processes (your in-process `BotMesh` + run queue is the right shape on one Mac), removal of `/` skills menu.

## Suggested next releases
| Release | Items |
|---|---|
| **0.9.1 — Trust** | 1 untrusted envelope, 2 memory taint, 3 pre-compaction flush, 6 watchdog |
| **0.10 — Control** | 4 Custom Rules, 5 fallback chain, 7 routing with visible model, 10 notifications |
| **0.11 — Learning** | 8 curator, 9 script gates, 11 Library, 13 memory timeline |
| **1.0 — Mac-native** | 14 App Intents/Spotlight, 12 draft/reconnect cards, 16 MCP server |

## Round 2 sources
[Grok Bot changelog](https://x.ai/changelog/bot) · [Grok Bot model routing](https://www.mindstudio.ai/blog/grok-bot-model-routing-upgrade) · [OpenClaw architecture](https://theagentstack.substack.com/p/openclaw-architecture-part-1-control) · [OpenClaw memory docs](https://docs.openclaw.ai/concepts/memory) · [OpenClaw 2026.8.1 memory notes](https://docs.openclaw.ai/releases/2026.8.1/memory) · [Hermes curator/kanban](https://github.com/nousresearch/hermes-agent) · [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) · [IronClaw](https://github.com/nearai/ironclaw) · [NanoClaw](https://github.com/qwibitai/nanoclaw) · [Goose](https://github.com/block/goose) · [Muse vs Dots](https://www.tomsguide.com/ai/meta-muse-vs-chatgpt-dots-i-compared-the-new-ai-agents-and-theyre-not-as-similar-as-they-look)


## Round 2 implementation status (v0.10.0)

Built: untrusted-content envelope (1), memory provenance and taint with approval gate (2), pre-compaction memory save (3), scoped allow rules edited from the card and in settings (4), provider fallback chain and non-streaming retry (5), tool watchdog (6), light-model routing with the answering model shown (7), skill usage counts, `/learn`, proposals and curator (8), routine script gates (9), actionable notifications (10), Library (11), reconnect and draft cards with per-bot "always send" (12), inspectable memory with Trust/Pin/Delete (13), App Intents and Spotlight (14), recipes (15), MCP control plane (16), OTLP tracing (17), request_secret with `{{secret:NAME}}` injection and two-way leak scanning (18).

Not built, and why: Grok Bot's per-bot accent colour, quote-selection-into-prompt, word-synced voice memos and 1Password hookup (polish, not safety or control); a Shortcuts *trigger* that fires without the app running (needs a separate helper); injection of secrets into shell commands (would show in the approval card); an iPhone companion.

**Follow-up (also v0.10.0):** per-bot accent colour, ⌘L quote-into-reply, read-aloud with a word-synced transcript (system voices), 1Password via `op://` references, `grizzybot://` links (the trigger that wakes the app from Shortcuts, scripts, and launchers), secrets in shell commands via environment variables, and a phone companion (mobile web app, not a native iOS app). Still open: a native iOS app with push notifications.
