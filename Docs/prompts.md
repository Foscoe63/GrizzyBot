# Prompts and tool descriptions

Everything the model reads lives in `Sources/GrizzyBotCore/Prompts/`, not inline in logic.

| File | Holds |
| --- | --- |
| `AgentLoop.prompt.swift` | `AgentLoop.PromptSection`: the system prompt sections |
| `AgentRecovery.prompt.swift` | `AgentPrompts`: loop-guard, length/empty-reply, summary and memory-flush prompts |
| `AgentTools.tool-definition.swift` | Built-in tool names, descriptions and JSON schemas (`AgentToolCatalog.chatTools`) |
| `PromptVersion.swift` | `PromptVersion.current` |

## Conventions
- Prompt text is authored only in `*.prompt.swift` / `*.tool-definition.swift` files. Logic files call into them.
- `PromptVersion.current` is a 12-hex-char SHA-256 over the rendered system prompt (fixed date), every `AgentPrompts` string and every built-in tool's JSON. Editing any wording changes it automatically; there is no manual bump.
- Dynamic parts (bot name, tools, dates) are rendered with fixed sample inputs so the hash only reflects authored text.
- Rakazo hashes source files too; a compiled app cannot, so the hash covers rendered output only.
- Not yet moved: small inline nudges such as `QueuePlanner.steerNote`, `DisabledBuiltinFallback.loopNudge` and the MCP nudges in `AgentLoop.runCore`.
