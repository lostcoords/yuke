# Customize yuke

yuke reads one profile at startup and on `/reload`: `config.json` and the plugin folders it lists. A plugin can add commands, keys, status items, model tools, event listeners, and engine hooks.

Start with [your first plugin](first-plugin.md). It adds one command and shows the manifest, type check, load, and reload cycle.

## Choose a mechanism

Use the smallest mechanism that fits the task:

| Task | Mechanism | Guide |
|---|---|---|
| Give the model reusable instructions | A skill in `skills/`, or workspace instructions in `AGENTS.md` | [Skills](engine.md#prompt) |
| Add an operation the model can call | `ctx.tools.define` | [Tools](tools.md) |
| Block, approve, or replace an engine action | `ctx.hook` | [Engine hooks](engine.md#engine-hooks) |
| Observe a change without blocking it | `ctx.on` | [Events](plugins.md#events) |
| Add a command, key, status item, style, or dialog | The `tui` capability | [UI](ui.md) |
| Update a clock or animation while idle | `tui.tickable` | [Frame-loop clocks](ui.md#frame-loop-clocks) |
| Browse and open saved sessions | `client.sessionList` and `showSession` | [Session browsing](plugins.md#browse-and-open-sessions) |
| Change transcript rows or tool headings | `chat.render` | [Transcript](ui.md#transcript) |
| Share a service between plugins | `uses`, `provides`, `ctx.get`, `ctx.provide` | [Capabilities](plugins.md#capabilities) |
| Change a public method for a plugin's lifetime | `ctx.advise` | [Advice](plugins.md#advice) |
| Replace a bundled surface | `disable` and a compatible replacement | [Bundled plugins](plugins.md#bundled-plugins) |
| Connect an external tool server | MCP configuration | [MCP servers](engine.md#mcp-servers) |

Tools, hooks, and engine events work without the TUI. Commands and views need the [TUI composition](profile.md#modes). Event dispatch does not await async listeners. Use a hook when async work must block an engine action.

## Documentation order

1. **Markdown guides** explain concepts and common recipes.
2. **`yuke.d.ts`** is the authoritative reference for exact public names, types, signatures, null values, and errors.
3. **`examples/`** contains complete patterns that CI type-checks against the declarations.
4. **Source inspection** is a last resort for undocumented behavior and implementation details.

An installed release puts these guides in `~/.local/lib/yuke/docs/`. The installer links `yuke.d.ts` into the [profile](profile.md). See [Types](types.md#find-a-declaration) for focused `grep` commands. Do not infer a public API from an implementation name that is absent from `yuke.d.ts`.

| Page | Read it to |
|---|---|
| [Profile](profile.md) | write `config.json` and a plugin folder, learn the startup modes, and verify a change |
| [Providers](providers.md) | configure credentials, providers, and local model servers |
| [Plugins](plugins.md) | write a plugin and customize events, chat, or bundled plugins |
| [UI](ui.md) | add commands, keys, status items, styles, and dialogs |
| [Tools](tools.md) | define a model tool and return its result |
| [Engine](engine.md) | add hooks, subagents, and MCP servers |
| [Types](types.md) | find declarations and type custom events or capabilities |

## Examples by task

Each file is a plugin entry. Its header gives the manifest and any replacement settings. Save it as the entry of a listed plugin folder. Use the installed release's declarations for a profile check.

| Example | Task | `uses` | Modes and behavior |
|---|---|---|---|
| [hello.js](examples/hello.js) | One command; the first-plugin tutorial | `tui` | TUI and check; additive |
| [plugin.js](examples/plugin.js) | Tool, hook, event, command, key, and status | `tui` | Tool, hook, and event in all modes; UI in TUI and check |
| [lifecycle.js](examples/lifecycle.js) | Timer cleanup, owned child, canceled I/O | `tui` | TUI and check; additive; starts a POSIX child |
| [picker.js](examples/picker.js) | Validated picker and a line-input command | `tui` | TUI and check; additive |
| [chat-api.js](examples/chat-api.js) | Current-session state and a focused-draft command | `tui` | TUI and check; additive |
| [stopwatch.js](examples/stopwatch.js) | Cached status and frame-loop start/stop | `tui` | TUI and check; additive; uses wall time |
| [session-picker.js](examples/session-picker.js) | Paginated session list and safe pane switch | `tui` | TUI and check; additive; needs bundled `sessions` or a compatible replacement |
| [sidebar.js](examples/sidebar.js) | Layout advice for a chat sidebar | none | Draws with the bundled chat in the TUI; check loads the advice |
| [roomy-chat.js](examples/roomy-chat.js) | Replace the `chat` capability | `tui` | TUI and check; provides `chat`; disable bundled `chat` |
| [tree-transcript.js](examples/tree-transcript.js) | Stacked renderer and a details window | `tui`, `chat` | TUI and check; additive renderer |

`yuke check` loads TUI plugins without a terminal. It does not prove that input, layout, or drawing is correct. Use a live TUI to check those behaviors. Use the [isolated check](profile.md#isolated-check) before loading unverified code into your normal profile.
