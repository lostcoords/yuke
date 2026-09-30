---
name: yuke
description: Customizes the yuke coding agent through its profile. Use when the user wants to write or fix a yuke plugin or index.js; add a yuke command, key binding, status bar item, style, dialog, model tool, engine hook, event listener, config value, subagent, or MCP server; edit providers.json for an API key, a local server, or a model; or find out why a profile change does not load or show.
---

# yuke profile

## Gotchas

- yuke runs `index.js` only at startup. After a change, tell the user to restart yuke. `/reload` does not read the profile again.
- To see a value, call `print(value)` or `ctx.print(value)`: `yuke check` prints it, and `~/.local/state/yuke/yuke.log` keeps it. A debug line never toasts.
- `yuke.d.ts` is large. Search it with `grep -n`, and read about 40 lines around a match.
- A callback that is not written inline in the call has no inferred types, and the strict editor options reject it. Annotate it, for example `/** @type {import("yuke:chat").Render} */`.
- Listen with `ctx.on`, not `events.on`: `ctx.on` removes the listener when the plugin unloads.
- An engine event (`run.started`, `run.done`, `message.*`, `tool.*`) passes the whole drain, not one fact. When `ev.type === "session"`, `ev.session` is the session id and `ev.facts` lists the facts.
- TUI code goes in `ctx.inject(["tui"], (c) => …)`. That block does not run in `yuke -p` or `yuke --rpc`.
- The transcript look is a stack of renderers (`c.chat.render`). A new look stacks on the default; a hook that answers `undefined` passes to the one below.
- `providers.json` can hold API keys inline. Read and edit it as needed, but do not print a key. Keep the mode `0600`. `yuke check` validates it, `yuke login` shows the state of each provider, and `/reload-providers` applies an edit without a restart.

## Workflow

1. Find the API (below).
2. Edit `index.js` in the profile (`$XDG_CONFIG_HOME/$YUKE_APPNAME`, default `~/.config/yuke`), or a file it imports. Leave `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` as they are: the installer owns them.
3. When `tsc` exists: `tsc -p <profile>/jsconfig.json`.
4. `yuke check`. Exit 1 means an error, and stderr names it. Fix it and run the check again.
5. Tell the user to restart yuke.

## Find the API

Each export in `yuke.d.ts` has a summary. The `declare module "yuke..."` blocks at the top map an export to its definition, for example `export import currentPane = $session.currentPane;`. Search `declare namespace $session` for the body.

| Need | Search |
|---|---|
| The focused pane, its composer and session | `currentPane`, `currentEntry` |
| The workspace root | `toolCtx.workspaceRoot` in a tool; `currentEntry()?.session.root` elsewhere |
| Composer text | `class TextInput` (`insert`, `setText`) |
| The model of a session | `modelSelector`, event `model.changed` |
| Files | `readFile`, `writeFile`, `stat` |
| A list to choose from | `export const ui`, `PickOptions` |
| An event name and its arguments | `interface EventsBase` |

## Docs

The guides are in `~/.local/lib/yuke/docs/`, the version of the installed yuke. In the yuke repository, read `docs/` there. Read the one page that fits the task:

- `profile.md`: files, modules, debugging, the check.
- `providers.md`: `providers.json`, API keys, login, local servers, custom models.
- `plugins.md`: lifecycle, events, capabilities, advice, bundled plugins, the chat pane.
- `ui.md`: commands, keys, the status bar, styles, dialogs, and transcript renderers.
- `vim.md`: composer Vim and transcript Vim modes and keys.
- `engine.md`: model tools, engine hooks, config, the prompt, subagents, MCP.
- `types.md`: types for your own events and capabilities.
- `examples/plugin.js`: a complete plugin to copy from.

Last resort: the source at `https://github.com/lostcoords/yuke`, at the tree for `yuke --version`: tag `v<version>`, the commit after `+` in a nightly, or `main` for a `-dev` build.
