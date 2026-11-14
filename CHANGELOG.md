# Changelog

User-visible changes, newest first. The current version lives in `project.yml`.

## 0.13.0 — teams as files

- **Review before you import.** Every way of opening a team (file, link, library, Open With, drop) shows one review sheet first: what it adds, which departments to install, and an accounts checklist. After import it shows what was created and what is still to connect.
- **Teams carry a connector checklist.** A team file can list the accounts it works best with (Gmail, Slack, …). Nothing is connected for you and no credentials are included.
- **Departments.** A team file can group bots and rooms into named departments, and you can install just some of them.
- **A proper export step.** Settings → Teams → Export team… lets you choose the bots, label each with a department, and pick which connected accounts to suggest (service name only).
- **Team library.** Settings → Teams → Browse teams… lists three built-in teams (Newsroom, Support Desk, Research Lab) and any online library you point it at: a JSON index of team files that anyone can host.
- **Import from a link, and from Finder.** Fetch an https team file (512 KB cap), drop one on the Teams settings, or use Open With → GrizzyBot on a `.team.md` file or drag it onto the Dock icon. Older team files still import unchanged.
- **Local servers check Host and Origin.** The control-plane and companion servers refuse requests from other websites.

## 0.12.2 — leaner Local MLX and a provider switch that sticks

- **Local MLX uses far less memory.** Its buffer cache was allowed to grow to half of RAM on top of the model weights; it is now capped at 1 GB and cleared after each turn.
- **Follow-up turns start faster.** Local MLX keeps the previous turn's prompt cache and only processes the new part of the prompt. Models whose layers cannot be trimmed still process the full prompt.
- **Turning a provider off sticks.** A disabled provider (for example Local MLX after you move to LM Studio) no longer keeps serving chats; GrizzyBot falls back to an enabled provider that has a model chosen.

## 0.12.1 — readable, collapsible always-allow rules

- **Always-allow rules are legible.** In a bot's settings the rule text was nearly the same colour as the background; it is now white.
- **The list folds.** The "Always-allow rules" heading has a chevron that turns to open and close the list.

## 0.12.0 — a smarter knowledge index, leaner context, and team check-ins

- **Knowledge search is an index now.** Folder sources are split into heading-scoped sections, so a hit is the part of a note that matched, titled with its heading trail. Ranking is hybrid: keyword (BM25) plus on-device semantic similarity (NaturalLanguage embeddings; keyword-only if unavailable). Only files whose size or modification time changed are re-read, so an unchanged vault costs a directory pass. `[[wikilinks]]` are followed and shown as linked notes. Settings → Knowledge shows "N indexed, M skipped" with reasons, a **Rebuild** button, and a **test search** that shows what a given bot (or you) would get back.
- **Scope a source.** Index only chosen subfolders and grant it to specific bots; a source can also be switched off without being deleted. Subfolders that are absolute, `~`, or climb out through `..` or a symlink are refused.
- **Tool output costs less context.** Large tool results are kept in full per run and shown to the model compressed by type (JSON, logs, code, text). The new `recall_result` tool searches or reads the original. Compaction now leaves a digest of the dropped messages instead of a stub, and the new `pin_fact` tool keeps a note across compaction and turns. Savings are counted in the run log and usage records.
- **Team check-ins.** The Chief of Staff can run heartbeat check-ins at fixed local times (up to six), skipped while you're chatting. Each is handed a snapshot of waiting approvals, recently run routines and the roster, and answers `HEARTBEAT_OK` when there is nothing to say. Configure them in the Chief of Staff's settings.
- **Hosted model lists.** Connecting a hosted provider (OpenRouter, OpenAI, Anthropic, …) can fetch its model list, and the composer model picker is searchable.
- **Settings tidy-up.** The Settings pages share one layout kit, and Governance gained more detail.
- **Fixes.** A stopped run no longer leaves live Allow / Always allow / Deny buttons on its approval card, and cards orphaned by older builds are cancelled when a workspace loads. A room member who passes keeps clean sidebar previews.

## 0.11.6 — quieter rooms, and a lead can stop a delegate

- **A room member can pass.** A member with nothing to add, or a message meant for someone else, replies `[PASS]`: nothing is posted and nobody it @mentions is pulled in. If every bot asked passes, the room says so ("Ada had nothing to add") instead of going silent.
- **A lead can stop a delegate.** `stop_bot` ends the run of a bot you handed work to with `message_bot`, marks the handoff failed, clears any approval it was waiting on, and tells the bot why (one extra turn for it). It only reaches bots you have an open job with, and like `check_bot` it has no switch of its own.

## 0.11.5 — delegates get the right tools

- **A job that needs a tool the bot lacks is caught before it starts.** Handing a job to a bot with no shell that says "run npm install" now comes straight back to the lead: which tool is missing, which bots have it, and what else to do — instead of the delegate flailing for twenty minutes. The check uses a short list of unmistakable phrases, so ordinary wording never blocks a handoff; `anyway=true` sends it regardless.
- **Lend a tool for one job.** `message_bot` takes `grant_tools` (`shell`, `read_file`, `write_file`, `edit_file`, `list_files`, `web_search`). The lead can only lend what it has itself, you are asked first — auto-approve doesn't skip that — and the loan ends when the job does. While a bot is running on a loan it asks you before *every* approval-gated action, whatever its own auto-approve or allow rules say. Memory, secrets, routines, delegation, plugins and the computer can't be lent.

## 0.11.4 — every tool switch works, and agents import from folders

- **Switches that wouldn't switch off now do.** Some tools came on silently with another: Shell turned on *List shortcuts*, *Run shortcut* and *Routines*; Remember turned on *Search memory*, *Forget* and the search tools; Spawn bot turned on *Message bot*; Request takeover turned on the Screenshot/Click/Type tools. They showed as on and ignored you. Each tool is now its own switch. Bots you already have keep exactly the tools they had (written out as real switches the first time 0.11.4 opens); after that, turn any of them off individually. Tools the agent can't work without (todo, complete, clarify, capability discovery, canvases and artifacts) no longer show a switch that did nothing.
- **Import an agent folder.** The **+** menu has a third item, *Import agent folder…*. Pick a folder with a `SKILL.md` (at the top, or under `skills/<name>/`) and, usually, an `agents/*.yaml`: you get a normal bot named from the agent file's `display_name`, described by its `short_description`, coloured with its `brand_color` and wearing its icon. The skill is saved to your skill library and switched on for that bot, and the whole folder (references, assets) is copied into the bot's home so the skill's `references/…` paths can be read. The skill and every Markdown file in the folder are scanned first; if anything looks risky you're asked before it's imported.

## 0.11.3 — a delegate can't run forever

- **Handed-off jobs time out after 20 minutes.** A bot working on a job another bot gave it is stopped if it is still running 20 minutes after the handoff, and the lead gets the usual *did not finish* notice saying so. Time spent waiting for your approval doesn't count; the clock restarts once you answer.

## 0.11.2 — when a handoff goes quiet

- **A delegate that didn't deliver says so.** If a bot you handed work to finishes with nothing, or with only its own working-out ("Wait, that doesn't work… let me try…"), the lead now gets a short *did not finish* notice with where it got stuck and what to do next, not that text dressed up as an answer. The hand-off is recorded as failed.
- **Waiting is visible.** While a lead is idle until a bot it handed work to reports back, its chat shows *Waiting on Researcher · working · 12 min* (or *needs you* when that bot is held for an approval).
- **`web_fetch` keeps the start of a JSON response.** The middle used to be cut out of anything over 3.5k characters, which dropped star counts and licences from API responses. JSON is now pruned of bookkeeping (`*_url`, `node_id`, avatars, `has_*` flags, nulls), minified, and cut from the end with a note when it still doesn't fit, so thirty GitHub repos fit in one fetch.

## 0.11.1 — fixes from a real run

- **Bots can make routines.** The new `routine_manage` tool lets a bot create, list, pause, resume, and delete its own routines — "make that a routine, three times a week" now makes a real one instead of a cron job in the sandbox. The schedule is `cron` or `days` + `time` (`mon,wed,fri` at `9:00`), validated before anything is created, and never more often than every 15 minutes. You approve each new routine; a run that has read outside content needs you every time, whatever the bot's auto-approve setting. Bots only touch their own routines.
- **Auto-approve no longer covers the memory gate.** A run that read the web used to be able to write shared memory on an auto-approve bot. Now an unattended or auto-approve bot keeps such a fact as its own *unverified* memory, never shared or pinned, and cannot forget memory at all; an attended bot asks you. *Always allow* is no longer offered on these cards, a stored one is ignored, and the routine gate works the same way.
- **`message_bot` finds a bot by name or id in either field.** It used to say "No bot named Researcher. Bots: …, Researcher" when a model put the name in the id field. Partial names work when they're unambiguous.
- **Model reasoning stays out of the chat.** Providers that put the opening `<think>` in the prompt send reasoning followed by a bare `</think>`; that reasoning no longer appears in the progress bubble.

## 0.11 — the right bot answers

- **Chief of Staff auto-dispatch.** Turn on *Hand work to the best bot automatically* in the Chief of Staff's settings. A message that clearly belongs to another bot (or that @mentions one) goes straight to them; their answer appears in the Chief of Staff's chat under their name, with a note saying who got it and why. Anything unclear, mixed ("research this and email it"), or small talk stays with the Chief of Staff. Start a message with `!` to keep it there. If the other bot fails, the Chief of Staff does the job itself; if it needs an approval, you're told where to answer it. Stop ends the hand-off and stops that bot too.
- **Room routing.** New rooms send an un-addressed message to the member that fits it best (menu in the room header: *routing: best fit / first member*); the room says who was picked and why. An @mention always wins; existing rooms keep their old behaviour.
- **How it decides.** Rules first — free, instant, the same answer every time: the message against each bot's name, role, description, skills and the tools actually switched on for it. An optional **router model** (Settings → General → Delegation) is asked only when the rules can't call it, sees nothing but the message and each bot's role and abilities, and its answer is accepted only if it names a real candidate.
- **Limits stay with each bot.** A bot uses its own tools and permissions; handing work over never widens them on its own. The one exception is a tool the lead *lends* for a single job (`grant_tools`), which you approve first and which asks you at every use. The roster now shows what each bot can do (`can: web, files`), and a bot that hits a disabled tool is told which bots have it. Bots can opt out of automatic hand-offs.
- **Outside content can't be laundered through another bot.** If a bot had read a web page or email before it messages a peer, the peer is told and its run starts out untrusted, so memory writes still need your approval.

## 0.10 — trust, control, and the rest of the Mac

**Trust**
- **Outside content is fenced.** Web pages, plugin and MCP results, and emails reach the model between `EXTERNAL_CONTENT` markers, flagged when they try to give orders (override-instructions, secrecy, "save this to memory", hidden Unicode). A forged closing marker is defused.
- **Memory can't be poisoned quietly.** A run that read outside content cannot write shared or pinned memory (or forget anything) without your approval; its other facts are tagged `⟦untrusted⟧`, never overwrite a fact you wrote, and show as *unverified* in **What I remember** (Trust / Pin / Delete per fact).
- **Pre-compaction save.** Before a long chat is squeezed, the bot gets one quiet turn to `remember` what matters.
- **Secrets stay secret, both ways.** Outgoing tool calls are blocked if they carry one of your stored secrets or a known key shape; stored secrets are scrubbed from results. `request_secret` opens a private field; the value goes to the Keychain and the bot writes `{{secret:NAME}}` (web_fetch, plugin and MCP calls only).
- **Stuck tools can't freeze a run.** Every tool call has a hard limit, and Stop returns within seconds even if a tool ignores cancellation.

**Control**
- **Scoped Always-allow.** "Always allow" on a shell or file approval now adds a rule for that command or folder (`git status*`), never one that matches a chained command. List and remove rules in the bot's settings.
- **Model fallback chain, a light model, and non-streaming retry.** If the main model fails, the next one answers and the reply says so. Short conversational turns can go to a small or local model; the reply names the model used.
- **Actionable notifications.** An approval raises a macOS notification with Allow / Always allow / Deny.
- **Drafts.** Outgoing email and chat posts appear as an editable draft before sending; "Always send" turns drafts off for that bot. **Reconnect cards** replace retry loops when a sign-in expires.

**Learning**
- **Skill usage, `/learn`, and a curator.** `/learn` has the bot propose a skill (saved switched off); the Skills panel shows proposals to approve, tidy-up suggestions, and an archive (nothing is ever deleted; pinned and bundled skills are untouchable).
- **Routine pre-checks.** A routine can run a cheap shell command first; if it prints nothing, the model isn't called.
- **Recipes.** Parameterised tasks in Markdown, run with `/recipe name key=value`.
- **Library.** Everything a bot shared (artifacts, files, links), grouped by day.

**Reach**
- **Phone companion.** A mobile web page served from your Mac (scan a QR code, Add to Home Screen): see your bots, read and send messages, stop a run, Allow or Deny an approval. Loopback by default; reaching it from your phone is an explicit setting, with a token, a lockout after repeated wrong tokens, and a warning to use Tailscale. Secrets, "always allow", and settings stay on the Mac.
- **`grizzybot://` links** (`open`, `ask`, `run-routine`) for Shortcuts, scripts, and launchers. Anything that makes a bot do work is read back to you for a yes first, since a web page can open these too.
- **1Password.** A saved secret can be an `op://` reference; GrizzyBot reads it through the `op` CLI only at the moment of use.
- **Secrets in shell commands** work too: `{{secret:NAME}}` becomes `"$GRIZZY_SECRET_NAME"` in the command you approve, and the value reaches the process only through its environment.
- **Bot-coloured messages, ⌘L to quote a selection into your reply, and read-aloud with a live transcript** (the spoken word highlights; tap a word to start there — system voices only).
- **MCP server.** Claude Desktop, Cursor, or Claude Code can list your bots, read and search chats, message a bot and wait for the answer, stop a run, or switch a model — over loopback with a token. Approvals, deletion, keys, settings, and the computer are not exposed.
- **Siri, Shortcuts, Spotlight.** *Ask a Bot* and *Run a Routine* App Intents; bots are indexed in Spotlight.
- **OpenTelemetry tracing.** Optional OTLP export of run and tool-call spans (timings and counts only).

## 0.9 — always on

- **Messages while a bot is working.** Sending mid-run no longer starts a second, overlapping run. Settings → General → *Messages while a bot is working*: **Steer** (default) slips the message into the run at its next step, **Collect** answers everything you sent once the run ends, **Follow up** answers one at a time. Stop discards what was waiting.
- **Telegram.** Message your bots from your phone. The Mac long-polls Telegram, so nothing is exposed to the internet; only chats you pair are answered. See [Telegram](#-telegram).
- **Webhooks, heartbeats, and routine memory.** Routines can be fired by an outside program (loopback receiver, per-routine secret), run as a quiet **heartbeat** checklist that says nothing when all is well, and remember their previous report. See [Triggers](#-triggers).
- **Built-in commands:** `/context` (what is filling the window), `/goal` (a standing objective), `/plan` (plan without doing), `/compact`, `/usage`, `/rollback`.
- **Checkpoints.** Before `write_file` / `edit_file` / `move_file` / `delete_file` change anything, the previous state is saved; `/rollback` undoes the last run's file changes.
- **`search_sessions`.** A bot can search its own earlier chats and tasks (never a sibling's).
- **Skill scanner.** Imported skills are screened for pipe-to-shell, credential access, prompt-injection phrasing, hidden Unicode, and over-broad tool requests; risky ones are badged in the Skills panel and reported in the import result. They already start switched off.
- **Teams as files.** Settings → General → Teams exports bots, rooms, and routines as one Markdown file (no credentials, chats, or memory; secrets scrubbed; routines import paused, bots import asking-first). **Import agent folder…** brings in an OpenClaw/Hermes-style workspace (`SOUL.md`, `AGENTS.md`, `MEMORY.md`, `HEARTBEAT.md`, `skills/`).
- **Tamper-evident audit.** Audit events are hash-chained; Settings → Governance → *Verify audit trail* reports the first event whose link no longer holds.

## Fixed in 0.9

- **The secret scrubber missed real Anthropic keys** (`sk-ant-api03-…`) because it stopped at the first hyphen. It now also covers GitHub, Slack, Google, and AWS key shapes. This feeds diagnostics, Sentry, exports, and team files.

## 0.8 — Added

- **Artifacts.** Bots create documents, code, diagrams, SVG, HTML, and React apps that you keep, version, edit, and re-open — shared across every bot and mirrored to disk. Routines can create them unattended. See [Artifacts](#-artifacts).
- **Artifact panel** at ⇧⌘A or the chat-header icon: browse, step through versions, preview or read source, copy, export, delete, and create one by hand.
- **Syntax-highlighted editor** with line numbers for artifacts, covering Swift, JS/JSX/TS, Python, shell, CSS, JSON, HTML/SVG/XML, Markdown, and Mermaid. Saving appends a version, so restoring an old one is just editing it.
- **Local MLX.** On Apple Silicon, run MLX models **in-process** inside GrizzyBot (no API base URL): Rescan disk (Hugging Face cache / LM Studio / custom folders), optional Hugging Face search & download, pick **Runs in app** in Model Connect. See [Models](#-models).
- **Direct Google OAuth** with fixed loopback `http://127.0.0.1:8765` and a step-by-step Cloud Console guide in Settings → Connections.
- **The Google plugins now do what their descriptions promise.** Gmail **sends mail** (it never could, despite the tool advertising it), Calendar **creates and removes** events, Sheets **reads real cells and appends rows** (it was a stub), Docs **creates documents**, and Drive **uploads files**. See [Google / Gmail](#-google--gmail).

## 0.8 — Fixed

- **Google Calendar writes never reached Google.** `plugin_call` had no write path for `google-calendar`, so every event fell through to a fallback that returned a fabricated `wrote local` success without making a single API call. Reads worked the whole time, which made it look like a sync or scope problem. Events are now genuinely created and return a Google event link.
- **Google Calendar could not be read at all.** Every query went to Google's full-text `q=` parameter, so `primary` searched for the *word* primary and `2026-09-12` searched for that string in event titles — a healthy calendar always reported "No Calendar events", which is what sent a bot round in circles insisting the calendar was empty. Reads are now time windows, with dates, ranges, and `today` / `this week` understood, and a calendar named rather than identified is resolved against your calendar list.
- **Silent fake success for every other write-less plugin.** That same fallback reported success for Gmail, Drive, Docs, Jira, Asana and the rest. It now fails loudly and says nothing was sent.
- **`canvas_place_image` ignored the working folder**, unlike every other file tool, so an image a bot had just written came back as "No image to place."
- **The CI build had been broken since August** — every run failed at the first step on a compiler type-check timeout in `ContextCompactor.encodedSize`, so no test in the repo had actually run in CI. Rewritten as plain statements.
- **Overlay snapshot tests** compared an exact PNG hash, which cannot pass on any machine but the one that recorded it. Now a pixel comparison with a tolerance, plus the failing render saved for inspection.
- **Three flaky tests, each a real bug:** a data race in the parallel-tool test recorder (`@unchecked Sendable` with unsynchronised `append`), wall-clock `Task.sleep` waits left in `ProductSurfaceTests`, and parallel tests sharing the process-wide `FolderWatcherService` while it watched real directories. The suite now runs clean across repeated full runs.
