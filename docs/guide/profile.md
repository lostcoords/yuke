# Profile

The profile is the directory `$XDG_CONFIG_HOME/$YUKE_APPNAME`. The default is `~/.config/yuke`. `YUKE_APPNAME` must be a plain directory name. A second name keeps a second profile beside the first.

## Files

| Path | Owner | Rule |
|---|---|---|
| `config.json` | you | The settings and the plugin list. yuke reads it at startup and on `/reload`. A missing file is fine. |
| plugin folders | you | Each folder that `config.json` lists holds a `plugin.json`. Code is optional. |
| `jsconfig.json`, your own `*.d.ts` | you | Editor options and your types. See [Types](types.md). |
| `yuke.d.ts`, `yuke-modules.d.ts`, `yuke.jsconfig.json` | installer | Links into `~/.local/lib/yuke`. Read them. The next install replaces them. |
| `providers.json` | you | Provider credentials and routes. Keep it out of logs and out of git. See [Providers](providers.md). |

yuke keeps its data in `$XDG_DATA_HOME/$YUKE_APPNAME` (default `~/.local/share/yuke`). Do not edit it.

## config.json

`config.json` is JSON with `//` and `/* */` comments. yuke reads the keys below and ignores any other key. A JSON error names its line, and yuke starts with the defaults for that file.

```jsonc
{
  // The terminal UI. `yuke -p` and `yuke --rpc` ignore it.
  "tui": {
    "colors": "auto",
    "mouse": { "scrollLines": 3, "copyOnSelect": true },
    "keymap": { "chordMs": 1000 }
  },
  "systemPrompt": null,
  // Folders: a relative path resolves against this file, and an absolute path works as it is.
  "plugins": ["./plugins/hello"],
  // Bundled plugins that do not load.
  "disable": []
}
```

| Key | Default | Meaning |
|---|---|---|
| `tui.colors` | `"auto"` | The palette depth: `"auto"` follows `COLORTERM`, `"truecolor"` forces 24-bit colors, `"256"` forces the 256-color palette. |
| `tui.mouse.scrollLines` | `3` | Lines per wheel step. |
| `tui.mouse.copyOnSelect` | `true` | Copy a mouse selection. |
| `tui.keymap.chordMs` | `1000` | Milliseconds to wait for the next chord key. |
| `systemPrompt` | `null` | Replace the base prompt. `${workspace}`, `${session_id}`, and `${agent_name}` expand. |
| `plugins` | `[]` | Local plugin folders or public GitHub sources. A source, folder, manifest, or entry that fails reports an error. The other plugins load. See [GitHub sources](#github-sources). |
| `mcpServers` | `{}` | MCP servers by name. A workspace `.mcp.json` server with the same name replaces one. See [MCP servers](engine.md#mcp-servers). |
| `disable` | `[]` | Names of [bundled plugins](plugins.md#bundled-plugins) that do not load. A profile plugin can then provide their capability. Another name does nothing. |

## GitHub sources

A `plugins` entry can be a local folder string or a GitHub source object. Keep both kinds in the same list:

```json
{
  "plugins": [
    "./plugins/hello",
    {
      "github": "lostcoords/yuke-plugins",
      "ref": "main",
      "path": "plugins/vim-mode"
    }
  ]
}
```

- `github` is `OWNER/REPO` or `https://github.com/OWNER/REPO`. This first implementation supports public repositories only.
- `ref` is a branch, tag, or commit. Its default is `HEAD`, the repository's default branch. A full 40-character commit skips the ref lookup.
- `path` is a plugin folder inside the repository. Its default is `.`. It cannot leave the repository.

Yuke downloads a missing source before it starts the JavaScript host. It resolves a branch or tag to a commit, downloads that commit, and checks the selected manifest. It stores a complete snapshot under `<profile>/.plugin-cache/` and records the source and full commit in `source.json`. It does not rewrite `config.json` or run a separate installer. Local folder entries work as before.

Later starts and `/reload` reuse the complete cached snapshot without network access. A branch does not update silently. To select another version, change `ref` to a new commit or tag. To fetch a branch again, remove that source's cache folder while Yuke is stopped. Add `.plugin-cache/` to the ignore file if you keep your profile in version control.

The download uses Yuke's HTTP client. It needs no Git, GitHub CLI, or package manager. Each request has a 30-second deadline. Downloads have a 16 MiB limit. Unpacked archives have a 64 MiB limit and at most 10,000 entries. Yuke rejects archive links, special files, duplicate files, multiple roots, and paths that leave the snapshot. It does not fetch Git submodules or install dependencies.

A failed source reports a profile problem and does not publish a new snapshot. The other plugins still load. A complete snapshot publishes atomically; concurrent starts do not replace each other's files. Removing a source from `plugins` stops loading it, but its cache stays on disk.

A GitHub plugin has the same user rights as a local plugin. Listing it in the config authorizes Yuke to download and execute its entry at startup or reload. Inspect the source and pin a commit when you need a fixed review target. Use the [isolated check](#isolated-check) before changing your normal profile. Do not list a local and a GitHub copy of the same plugin name.

## A plugin

A plugin is a folder with a `plugin.json` ([Agent Plugins](https://github.com/agentplugins/agent-plugins-spec) 1.1.0). An entry module is optional. yuke reads its part under `extensions["sh.yuke"]`:

```json
{
  "name": "hello",
  "extensions": { "sh.yuke": { "entry": "./index.js", "uses": ["tui"] } }
}
```

[Your first plugin](first-plugin.md) shows the complete entry and loading workflow. [`examples/hello.js`](examples/hello.js) is its checked entry.

- `name` names the plugin. It prefixes the commands of the plugin. yuke reads `name` and `extensions["sh.yuke"]`, and it ignores the other fields.
- `entry` is the path of the entry module, relative to the folder. Its default export is `apply(ctx)`. It can be async, and startup waits for it.
- `uses` and `provides` list the capabilities that `ctx.get` reads and `ctx.provide` registers. See [Plugins](plugins.md#capabilities).
- `ctx.root` is the plugin folder, for the files of the plugin.
- `activation: { "workspaceContains": ".xyastack" }` limits the plugin to the sessions of a workspace that holds that file. The path is relative to the workspace root. A directory does not match. The tools, the engine hooks, the skills, and the MCP servers of the plugin reach only those sessions. Its commands, keys, and views stay in every frontend. Without `activation`, every session gets the plugin. yuke checks each rule the first time it uses a workspace, and the answer holds until a restart or a `/reload`.
- `mcp.json` lists the MCP servers of the plugin in an `mcpServers` object ([MCP servers](engine.md#sources-and-trust)).
- `skills/` holds the skills of the plugin, one folder with a `SKILL.md` for each skill. A skill keeps its plain name. The first skill with a name wins: the workspace `.agents/skills`, then `~/.agents/skills`, then the plugins in `config.json` order. yuke skips a later skill with the same name and posts a notice. The skills load even when the entry module fails.

[`examples/plugin.js`](examples/plugin.js) adds a command, a key, a status item, a model tool, an event listener, and a hook.

## Modules

| Import | Holds |
|---|---|
| `yuke` | `config`, `events`, `fs`, `env`, `fetch`, `exec`, `spawn`, `lines`, `net`, `jobs`, `client`, `children`, `utf8`, `diff`, and the plugin types |
| `yuke:ui` | views and widgets, `ui.pick`, `keys` |
| `yuke:chat` | `ChatView`, `ChatSurface`, `Transcript`, and helpers for a renderer: `toolHead`, `wrapRows`, `diffRows`, `openDetails`; `attachPath`, `attachClipboard` |
| `yuke:session` | `Session`, `sessions`, `currentSession()`, `currentPane()`, `currentEntry()`, `showSession` |
| `yuke:plugins` | `shell`, the bundled window layout, for a replacement |

An import of `yuke:internal/*` throws. A relative import works. Yuke does not resolve npm dependencies, so an npm import fails.

yuke runs ES2025 JavaScript (QuickJS-ng), with no Node or browser API: use the `yuke` modules for files, processes, and the network. A plugin runs with your user rights, so it can read and write any file and run any command.

## Modes

| Mode | Bundled TUI plugins and `tui` | Input and drawing | Profile tools, hooks, and engine events |
|---|---|---|---|
| `yuke` | Yes | Live terminal | Yes |
| `yuke resume <id>` | Yes | Live terminal on a saved conversation | Yes |
| `yuke check` | Yes | No terminal; load check only | Yes |
| `yuke -p` | No | Headless prompt | Yes |
| `yuke --rpc` | No | JSONL client | Yes |

Read `ctx.get("tui")`, and return early when it is `null`. Register model tools and engine hooks before that return, so all modes get them. A TUI registration that passes `yuke check` still needs a live input and drawing check.

## Check a change

Use the full workflow:

```sh
tsc -p <profile>/jsconfig.json
yuke check
# Save a copy of the typed draft.
# Run /reload in yuke after the active run ends.
```

- `tsc` checks the profile against the declarations of the installed release.
- `yuke check` loads the TUI composition without a terminal. It provides `tui`, so TUI code runs, and it prints debug lines, warnings, and errors to stderr. It counts only warnings and errors. It exits with status 1 on an error.
- `yuke check` runs plugins and opens the session store. It is not read-only.
- yuke reads `config.json` and the plugins at startup and on `/reload`. `/reload` stops every plugin and starts them again from the files on disk. Then it rescans `AGENTS.md` and the skills of each open chat.
- `/reload` keeps the panes, the split sizes, the focus, and the chat of each pane. A `shell` replacement starts with one new chat. A background job continues. Its end reaches the new plugins through `job.changed`. A typed draft is lost.
- `/reload` refuses while a run or a tool call is active. A notice says so.
- When the plugins of `config.json` stop the boot, `/reload` starts the core plugins without them. The notifications show the fault. Fix `config.json`, then run `/reload` again.

### Continue in another workspace

The `workspace` profile plugin owns `/cd` and `/pwd`. Copy `plugins/workspace` into the profile and list `"./plugins/workspace"` in `config.json`. It needs a build that exports `workspace` from `"yuke"`. Neither command loads without this plugin.

`/cd <path>` continues the current conversation in a new workspace. `/pwd` shows the current workspace without changing the conversation or its draft. `/cd` without a path also shows the current workspace.

The path can be absolute, relative to the current workspace, be `~`, or start with `~/`. The entire argument is one path, including spaces. Matching outer double quotes, single quotes, or backticks delimit the path. Yuke removes those delimiters without shell or variable expansion.

For an open chat, Yuke forks the committed history under a new session ID. The source chat stays unchanged. The fork keeps model settings, compaction, and attachment references. It does not copy child chats or background jobs.

Yuke reloads the profile and plugins with the destination as the default workspace. The destination supplies `AGENTS.md`, skills, plugin activation, and workspace MCP configuration. MCP trust still requires approval. File helpers, path completion, and new chats use the destination.

The command requires one pane and the bundled `shell`. It refuses while chat creation, a run, a tool call, or a continuation is active. It also refuses a queued input, pending compaction, a running background job, or an unsaved draft. A missing or inaccessible directory leaves the current chat and workspace unchanged. Selecting the current workspace does not fork or reload it.

A draft changes workspace without creating a chat. Plugin-owned state and timers reset on reload. If a profile plugin stops the new boot, the core fallback opens the destination fork. Input stays in the composer until the restored history opens. The fallback does not load profile commands. Fix the profile and reload to restore `/cd` and `/pwd`.

### Isolated check

This POSIX-shell recipe checks the installed [hello example](examples/hello.js) in a disposable profile and workspace. It needs TypeScript (`tsc`) and the installed files in `~/.local/lib/yuke`. It does not copy provider credentials. The yuke process gets a temporary home, config, data, and state directory and a clean environment.

```sh
(
  set -eu
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  lib="$HOME/.local/lib/yuke"
  bin="$HOME/.local/bin/yuke"
  profile="$scratch/config/yuke-doc-check"
  mkdir -p "$profile/plugins/hello" "$scratch/home" "$scratch/workspace"
  ln -s "$lib/jsconfig.json" "$profile/yuke.jsconfig.json"
  ln -s "$lib/types/yuke.d.ts" "$profile/yuke.d.ts"
  ln -s "$lib/types/yuke-modules.d.ts" "$profile/yuke-modules.d.ts"
  printf '%s\n' '{ "extends": "./yuke.jsconfig.json" }' > "$profile/jsconfig.json"
  printf '%s\n' '{ "plugins": ["./plugins/hello"] }' > "$profile/config.json"
  printf '%s\n' '{ "name": "hello", "extensions": { "sh.yuke": { "entry": "./index.js", "uses": ["tui"] } } }' > "$profile/plugins/hello/plugin.json"
  cp "$lib/docs/examples/hello.js" "$profile/plugins/hello/index.js"
  tsc -p "$profile/jsconfig.json"
  cd "$scratch/workspace"
  env -i HOME="$scratch/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" \
    XDG_STATE_HOME="$scratch/state" YUKE_APPNAME=yuke-doc-check \
    "$bin" check
)
```

Expect `hello · debug: hello loaded` and `0 error(s), 0 warning(s)`. The subshell removes the temporary files when it ends. Your normal profile, provider file, log, and session store stay outside the check.

For another plugin, copy its folder into the temporary profile instead of the hello entry. Change the manifest and `plugins` list to match. Keep relative assets inside that folder. Do not copy credentials. Check that plugin against the same declarations.

This is isolation, not a sandbox. A plugin still runs with your user rights. It can access an absolute path or run a command. This check does not verify compatibility with your normal plugin list. Inspect the code before loading it there.

Use a separate disposable TUI session to check input, drawing, and unload behavior. Do not use the shell recipe for a live session: its cleanup removes the temporary files as soon as the check ends. Follow the [first-plugin tutorial](first-plugin.md#5-load-and-run-the-command) for live reload and keep the draft-loss warning above.

## Debug a plugin

`print(...values)` and `console.log` post a `debug` line; `console.info`, `console.warn`, and `console.error` post at their own level. `ctx.print` names your plugin as the source. A string prints as it is, an error as its message, and any other value as JSON.

- `yuke check` prints each line as `source · level: message`.
- In the TUI, a warning, an error, or a plugin fault shows as a toast; a debug line never does. `notify:history` (`/messages`) lists the newest 100.
- Every mode appends each line, and yuke's own log, to `yuke.log` in the state directory (`$XDG_STATE_HOME/yuke`, by default `~/.local/state/yuke`). Each line starts with the process id. The file never rotates. A panic prints to stderr.

## Install links

Each install replaces `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` in the profile that `YUKE_APPNAME` names at install time, even a file of yours with the same name. It writes `jsconfig.json` only when none exists. It also links the `yuke` agent skill into `~/.agents/skills/yuke`, for every coding agent that reads that directory; your own entry at that path stays, and the installer prints a warning.

The links hold a path on this machine. A profile in git ignores them: add `yuke.d.ts`, `yuke-modules.d.ts`, and `yuke.jsconfig.json` to its `.gitignore`.
