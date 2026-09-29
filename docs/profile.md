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

[`examples/plugin.js`](examples/plugin.js) adds a command, a key, a status bar item, a tool, and a hook.

## Modules

| Import | Holds |
|---|---|
| `yuke` | `plugins`, `defineConfig`, `config`, `events`, `fs`, `env`, `fetch`, `exec`, `spawn`, `lines`, `net`, `jobs`, `client`, `utf8`, `diff`, and the plugin types |
| `yuke:ui` | views and widgets, `ui.pick`, `ui.select`, `keys` |
| `yuke:chat` | `ChatView`, `Transcript`, `labels`, `registerLabels`, `attachPath`, `attachClipboard` |
| `yuke:session` | `Session`, `sessions`, `currentSession()`, `currentPane()`, `currentEntry()`, `showSession` |
| `yuke:plugins` | optional plugins: `composerVim`, `transcriptVim`, `agents(options)`, `mcp(options)`; and `shell`, the bundled window layout, for a replacement |

An import of `yuke:internal/*` throws. A relative import works. yuke has no package manager, so an npm import fails.

yuke runs ES2025 JavaScript (QuickJS-ng), with no Node or browser API: use the `yuke` modules for files, processes, and the network. A plugin runs with your user rights, so it can read and write any file and run any command.

## Check a change

1. Type-check the profile, when `tsc` exists: `tsc -p <profile>/jsconfig.json`.
2. Run `yuke check`. It loads the profile as the TUI does, without a terminal, and prints each warning and error to stderr. It exits with 1 on an error. It runs your plugins and opens the session store, so it is not read-only.
3. Restart yuke. yuke runs `index.js` only at startup. `/reload` reads `AGENTS.md` and the skills again, not the profile.

## Debug a plugin

There is no `console` and no `print`. Call `c.interaction.notify(text, "warn")` to see a value.

- `yuke check` prints each warning and error as `source · level: message`.
- In the TUI, a warning or a plugin fault shows as a toast. `notify:history` (`/messages`) lists the newest 100.
- While the TUI runs, yuke writes its own log to `tui.log` in the data directory. Each start empties the file, so copy it before a restart. A panic prints to stderr.

## Install links

Each install replaces `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` in the profile that `YUKE_APPNAME` names at install time, even a file of yours with the same name. It writes `jsconfig.json` only when none exists. It also links the `yuke` agent skill into `~/.agents/skills/yuke`, for every coding agent that reads that directory; your own entry at that path stays, and the installer prints a warning.

The links hold a path on this machine. A profile in git ignores them: add `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` to its `.gitignore`.
