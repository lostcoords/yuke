# Profile

The profile is the directory `$XDG_CONFIG_HOME/$YUKE_APPNAME`. The default is `~/.config/yuke`. `YUKE_APPNAME` must be a plain directory name. A second name keeps a second profile beside the first.

## Files

| Path | Owner | Rule |
|---|---|---|
| `index.js` and the files it imports | you | yuke runs `index.js` at startup. A missing file is fine. |
| `jsconfig.json`, your own `*.d.ts` | you | Editor options and your types. See [Types](types.md). |
| `yuke.d.ts`, `yuke-modules.d.ts`, `yuke.jsconfig.json` | installer | Links into `~/.local/lib/yuke`. Read them. The next install replaces them. |
| `providers.json` | you | Provider credentials and routes. Keep it out of logs and out of git. See [Providers](providers.md). |
| `.mcp.json` | you | MCP servers for the `mcp` plugin. See [Engine](engine.md). |

yuke keeps its data in `$XDG_DATA_HOME/$YUKE_APPNAME` (default `~/.local/share/yuke`). Do not edit it.

## A plugin

```js
import { plugins } from "yuke";

plugins.use({
  name: "my-plugin", // unique; it prefixes the commands of the plugin
  apply(ctx) {
    ctx.inject(["tui"], (c) => {
      c.tui.command.add("hi", { desc: "Say hi", run: () => { c.interaction.notify("hi"); } });
    });
  },
});
```

[`examples/plugin.js`](examples/plugin.js) adds a command, a key, a status item, a model tool, an event listener, and a hook.

## Modules

| Import | Holds |
|---|---|
| `yuke` | `plugins`, `defineConfig`, `config`, `events`, `fs`, `env`, `fetch`, `exec`, `spawn`, `lines`, `net`, `jobs`, `client`, `utf8`, `diff`, and the plugin types |
| `yuke:ui` | views and widgets, `ui.pick`, `ui.select`, `keys` |
| `yuke:chat` | `ChatView`, `ChatSurface`, `Transcript`, and helpers for a renderer: `toolHead`, `wrapRows`, `diffRows`, `openDetails`; `attachPath`, `attachClipboard` |
| `yuke:session` | `Session`, `sessions`, `currentSession()`, `currentPane()`, `currentEntry()`, `showSession` |
| `yuke:plugins` | optional plugins: `composerVim`, `transcriptVim`, `agents(options)`, `mcp(options)`; and `shell`, the bundled window layout, for a replacement |

An import of `yuke:internal/*` throws. A relative import works. yuke has no package manager, so an npm import fails.

yuke runs ES2025 JavaScript (QuickJS-ng), with no Node or browser API: use the `yuke` modules for files, processes, and the network. A plugin runs with your user rights, so it can read and write any file and run any command.

## Modes

The TUI and `yuke check` load the [bundled plugins](plugins.md#bundled-plugins) and provide the `tui` capability. `yuke -p` and `yuke --rpc` do neither. Put every command, key, status item, dialog, and other TUI call inside `ctx.inject(["tui"], ...)`. Put model tools and engine hooks outside that block when all modes need them.

## Check a change

Use the full workflow:

```sh
tsc -p <profile>/jsconfig.json
yuke check
# Restart yuke.
```

- `tsc` checks the profile against the declarations of the installed release.
- `yuke check` loads the TUI composition without a terminal. It runs TUI injection blocks and prints debug lines, warnings, and errors to stderr. It counts only warnings and errors. It exits with status 1 on an error.
- `yuke check` runs plugins and opens the session store. It is not read-only.
- yuke runs `index.js` only at startup. `/reload` reloads `AGENTS.md` and skills. It does not reload the profile.

## Debug a plugin

`print(...values)` and `console.log` post a `debug` line; `console.info`, `console.warn`, and `console.error` post at their own level. `ctx.print` names your plugin as the source. A string prints as it is, an error as its message, and any other value as JSON.

- `yuke check` prints each line as `source · level: message`.
- In the TUI, a warning, an error, or a plugin fault shows as a toast; a debug line never does. `notify:history` (`/messages`) lists the newest 100.
- Every mode appends each line, and yuke's own log, to `yuke.log` in the state directory (`$XDG_STATE_HOME/yuke`, by default `~/.local/state/yuke`). Each line starts with the process id. The file never rotates. A panic prints to stderr.

## Install links

Each install replaces `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` in the profile that `YUKE_APPNAME` names at install time, even a file of yours with the same name. It writes `jsconfig.json` only when none exists. It also links the `yuke` agent skill into `~/.agents/skills/yuke`, for every coding agent that reads that directory; your own entry at that path stays, and the installer prints a warning.

The links hold a path on this machine. A profile in git ignores them: add `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` to its `.gitignore`.
