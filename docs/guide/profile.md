---
description: Configure yuke profiles, plugin sources, startup modes, and editor types.
---

# Profile

The profile is the directory `$XDG_CONFIG_HOME/$YUKE_APPNAME`. The default is `~/.config/yuke`. `YUKE_APPNAME` must be one plain directory name. A second name selects a separate profile.

An empty or relative XDG root counts as unset. yuke then uses the default directory under your home.

## Files

| Location | Contents |
|---|---|
| `$XDG_CONFIG_HOME/$YUKE_APPNAME` | `config.json`, `providers.json`, `plugins.lock`, your local plugins, and editor configuration. Default: `~/.config/yuke`. |
| `$XDG_DATA_HOME/$YUKE_APPNAME` | The session store, `auth.json`, installed Git plugins, and plugin data. Default: `~/.local/share/yuke`. |
| `$XDG_CACHE_HOME/$YUKE_APPNAME` | Files that yuke can create again, such as compiled TypeScript. Default: `~/.cache/yuke`. |

Keep credentials out of version control. `auth.json` holds account logins and stored API keys. `providers.json` configures routes and API-key variable names; its custom headers can also contain sensitive values. See [Providers](providers.md).

Keep `config.json`, local plugin source, and `plugins.lock` with your dotfiles if you want to reproduce a profile. Let yuke manage its data and cache files.

## config.json

`config.json` accepts JSON with `//` and `/* */` comments. A missing file uses the defaults. The schema is strict. An unknown field, a bad value, or a JSON error stops startup. An error names the file and the problem. A failed reload keeps the previous profile.

This configuration uses only bundled plugins:

```jsonc
{
  "plugins": [],
  "disable": [],
  "bundled": {},
  // Close an unheld session with running jobs after 30 minutes.
  "sessionIdleMinutes": 30
}
```

| Key | Default | Meaning |
|---|---|---|
| `plugins` | `[]` | Local plugin folders or Git source objects. The list can pass an `options` object to each plugin. |
| `disable` | `[]` | Bundled plugin names that do not load. An unknown name is an error. |
| `bundled` | `{}` | Options for bundled plugins, by plugin name. An unknown plugin name is an error. Each plugin checks its options. |
| `sessionIdleMinutes` | `30` | Minutes before an open session with running jobs and no holder closes and stops its jobs. An active turn or a holder prevents this idle close. |

See [Terminal UI](ui.md) for UI settings and [Engine](engine.md) for prompt hooks and MCP configuration.

### Local plugin options

A relative plugin path starts in the profile directory. An absolute path also works. A string entry gives the plugin no options. An object can give it options:

```json
{
  "plugins": [
    "./plugins/hello",
    { "path": "./plugins/project", "options": { "label": "work" } }
  ]
}
```

The folders must exist. Each plugin defines its own option schema; `label` in this example is an option for a plugin that accepts it.

## Git sources

A Git source specifies a repository URL:

```json
{
  "plugins": [
    {
      "git": "https://github.com/OWNER/REPOSITORY.git",
      "ref": "main",
      "folder": "plugins/example",
      "options": {}
    }
  ]
}
```

Replace the URL and folder with a plugin that you trust. `ref` selects a branch, tag, or commit. Without `ref`, the source follows the default branch. `folder` selects a folder inside the repository; its default is the repository root. It cannot be absolute or contain `..`.

Run `yuke plugin sync` after you add a Git source. The manager needs Git. It records a commit in `plugins.lock` and installs that commit. Startup and reload use the installed commit without network access.

| Command | Behavior |
|---|---|
| `yuke plugin list` | Show the configured plugins, locked commits, and install states without network access. |
| `yuke plugin sync` | Install locked commits and lock each new Git source at its selected ref. |
| `yuke plugin sync --locked` | Install locked commits. Fail if the lock does not match the configuration. Keep the lock unchanged. |
| `yuke plugin update NAME...` | Update selected Git plugins by their manifest names. |
| `yuke plugin update --all` | Update all Git plugins. |

An update shows the commit changes and asks for confirmation before it writes `plugins.lock`. Add `--yes` to update without that question. Run `/reload` in open sessions after a sync or update to load the installed version.

A plugin runs with your user rights. Inspect its source before you install it.

## A plugin

A local plugin folder holds `plugin.json`. The manifest names the plugin and can declare an entry under `extensions["sh.yuke"]`. The entry can be TypeScript or JavaScript. See [Your first plugin](first-plugin.md) for a complete example and [Plugins](plugins.md) for services and lifecycle rules.

## Modules

The installed library supplies public `yuke:*` modules and their types. Plugin and tool helpers come from `yuke:plugins` and `yuke:tools`. Files, processes, networking, and other host APIs have separate modules. See [Public types](types.md) for the module list and exact declarations.

yuke uses QuickJS-ng. It does not supply Node or browser APIs. Use the public host modules instead.

## Modes

| Command | Behavior |
|---|---|
| `yuke` | Open the terminal UI with a new conversation. |
| `yuke --resume ID` | Open a saved conversation in the terminal UI. |
| `yuke -c` | Open the conversation in the current directory with the newest saved event. |
| `yuke -p 'PROMPT' --model PROVIDER/MODEL --reasoning default` | Run one task without the UI. |
| `yuke --rpc` | Serve the JSONL protocol on stdin and stdout. |
| `yuke test [PATHS...]` | Run `*.test.ts` files with the test host and a fake model. |

Plugins can load in terminal, headless, and protocol modes. Only terminal mode supplies the TUI service. A plugin must handle its absence in other modes. See [Plugins](plugins.md).

## Check a change

Run the editor check against the profile configuration:

```sh
tsc -p ~/.config/yuke/tsconfig.json
```

Use your actual profile path if it differs. For behavior tests, run `yuke test` on test files that use `yuke:test`. A test uses an isolated app and a fake model. It does not need provider credentials. See [Public types](types.md) for the test API.

A type check does not verify terminal input or drawing. Start a separate terminal session to check those behaviors.

`/reload` reads the configuration, providers, and plugin files again. Wait for active turns to end before you reload. A reload replaces the JavaScript runtime. Module state resets. Process jobs continue, but plugin-owned jobs stop. A failed reload keeps the previous plugins and providers. See [Terminal UI](ui.md) for the reload controls and pane state.

### Isolated check

Use a temporary home, workspace, and XDG directories before you load unverified code. For example, start an empty terminal session without provider credentials:

```sh
(
  set -eu
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  bin="$HOME/.local/bin/yuke"
  mkdir -p "$scratch/home" "$scratch/workspace"
  cd "$scratch/workspace"
  env -i HOME="$scratch/home" PATH="$PATH" \
    XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" \
    XDG_CACHE_HOME="$scratch/cache" YUKE_APPNAME=yuke-doc-check \
    "$bin"
)
```

Press **Ctrl+Q** to exit. The subshell then removes the temporary files, including any session data. This empty profile checks startup only. To test a plugin, prepare its profile files in the temporary config directory before you start yuke. Do not copy credentials there.

This is isolation, not a sandbox. A plugin can still access an absolute path or run a command with your user rights.

## Debug a plugin

Console output becomes a `notice` notification from the source `console`. Plugin notices and script faults also reach the active frontend. Inspect terminal notices or the `notice` messages of an RPC client. CLI startup errors go to stderr.

Capture stderr or protocol notifications when you need a record of a failure. Do not publish credentials or private task content in a diagnostic report.

## Editor configuration

The installer creates `<profile>/tsconfig.json` only when that path is absent. It extends the absolute path `~/.local/lib/yuke/tsconfig.json`, includes `./**/*.ts`, and excludes `./node_modules`. The actual file contains the full library path, not `~`.

The library contains `modules/plugins.ts`, `modules/tools.ts`, and `modules/protocol.ts`. The `types/` directory contains `globals.d.ts`, `ai.d.ts`, `chat.d.ts`, `fs.d.ts`, `net.d.ts`, `process.d.ts`, `test.d.ts`, `transcript.d.ts`, and `tui.d.ts`. These files declare the host modules and globals.

The library configuration includes that public source, those declarations, and the protocol bindings. It maps `yuke:*` to the public module source and `yuke:protocol/*` to the protocol bindings. It excludes private modules and `native.d.ts`.

An existing editor configuration stays unchanged on upgrade. Keep its library path and options current. See [Public types](types.md). The generated profile configuration has a machine-specific absolute path. Update it when you move the profile to another machine.
