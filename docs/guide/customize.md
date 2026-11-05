---
description: Choose a plugin, tool, hook, service, or terminal extension for a task.
---

# Customize yuke

A profile selects plugins and their options. Plugins add shared services, session behavior, and terminal UI. Start with [Your first plugin](first-plugin.md) for the manifest and entry module.

## Choose a mechanism

Use the smallest mechanism that fits the task:

| Task | Mechanism | Guide |
|---|---|---|
| Give the model reusable instructions | A skill or `AGENTS.md` | [Prompt](engine.md#prompt) |
| Add an operation the model can call | `s.tools.define` in `session` | [Tools](tools.md) |
| Approve or change engine behavior | `s.hook` in `session` | [Engine hooks](engine.md#engine-hooks) |
| Observe a host fact without blocking it | `ctx.on` in `apply` | [Events](plugins.md#events) |
| Add commands, keys, status items, or views | `ctx.get("tui")` in `apply` | [UI](ui.md) |
| Browse or control sessions | `ctx.get("sessions")` | [Session handles](plugins.md#browse-and-open-sessions) |
| Change chat presentation or open a chat pane | The `chat` service | [UI](ui.md) |
| Share a typed value between plugins | `uses`, `provides`, `ctx.get`, and `ctx.provide` | [Services](plugins.md#services) |
| Replace bundled behavior | Disable a bundled plugin and add a replacement | [Bundled plugins](plugins.md#bundled-plugins) |
| Connect a local external tool server | Stdio MCP | [MCP servers](engine.md#mcp-servers) |
| Make a model request outside a conversation | `generateText` from `yuke:ai` | [Model requests](engine.md#tool-free-model-requests) |

Named `apply(ctx)` runs once per runtime. Named `session(s)` runs once per open session. Both can return cleanup. Put model tools and engine hooks in `session`; they then work without the TUI. `ctx.get("tui")` returns `undefined` in headless modes.

The host awaits engine hooks, but not fact listeners. Use a hook when async work must block an action. Use a listener when you only need to observe it.

## Public APIs

The public modules separate each concern:

- `yuke:plugins`: contexts, services, session handles, host facts, and hooks.
- `yuke:tools`: schemas, inferred arguments, tool definitions, and results.
- `yuke:protocol`: session settings, blocks, saved events, and update types.
- `yuke:ai`: standalone model requests.
- `yuke:fs`, `yuke:process`, and `yuke:net`: host I/O.
- `yuke:tui`, `yuke:chat`, and `yuke:transcript`: terminal views and conversation presentation.
- `yuke:test`: isolated hosts and runtime tests.

Use [Types](types.md) for declaration setup and exact signatures. Use [Plugins](plugins.md) for lifetimes and services. Use [Profile](profile.md) and [Providers](providers.md) for configuration. Do not import `yuke:internal/*`.

## Examples by task

[Your first plugin](first-plugin.md), [Tools](tools.md), and [Engine](engine.md) show small entry modules. [UI](ui.md) covers terminal patterns. Keep a plugin's engine behavior separate from its optional UI.

A type check verifies names and value shapes. A runtime test verifies behavior. Test terminal input and drawing in a live TUI as well.
