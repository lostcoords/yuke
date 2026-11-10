---
description: Configure yuke folders, profiles, and plugins.
---

# Configuration

yuke keeps its files in these folders. For the first three, yuke uses each XDG variable when it is set, and falls back to the default when it is not.

| Folder | Default | Contents |
|---|---|---|
| `$XDG_CONFIG_HOME/yuke` | `~/.config/yuke` | `config.json`, `providers.json`, `mcp.json`, `plugins.lock`, your local plugins, and editor configuration |
| `$XDG_DATA_HOME/yuke` | `~/.local/share/yuke` | Sessions, `auth.json`, installed Git plugins, and plugin data |
| `$XDG_CACHE_HOME/yuke` | `~/.cache/yuke` | Files that yuke can create again, such as compiled TypeScript |
| `~/.local/lib/yuke` | `~/.local/lib/yuke` | The public TypeScript API: modules, type declarations, and protocol bindings. |

## Profiles

yuke supports multiple profiles. Set `YUKE_APPNAME` to use another one:

```sh
YUKE_APPNAME=yuke-work yuke
```

This profile uses `~/.config/yuke-work`, `~/.local/share/yuke-work`, and `~/.cache/yuke-work`. The name must be a plain folder name.

## config.json

`config.json` accepts JSON with `//` and `/* */` comments. A missing file uses the defaults. The schema is strict, so an unknown field, a bad value, or a JSON error stops startup. An error names the file and the problem. A failed reload keeps the previous profile.

This configuration uses only bundled plugins:

```json
{
  "plugins": [],
  "disable": [],
  "bundled": {},
  "sessionIdleMinutes": 30
}
```

| Key | Default | Description |
|---|---|---|
| `plugins` | `[]` | Your plugins: local folders or Git repositories. See [Plugins](#plugins). |
| `disable` | `[]` | [Bundled plugins](plugins.md#bundled-plugins) to turn off, by name, such as `["toasts"]`. |
| `bundled` | `{}` | Options for [bundled plugins](plugins.md#bundled-plugins), by name. Each plugin checks its own options. |
| `sessionIdleMinutes` | `30` | How long background jobs keep running in a session that no pane or client has open. After this time, yuke closes the session and stops its jobs. |

See [Terminal UI](ui.md) for UI settings, [Engine](engine.md) for prompt hooks, and [MCP servers](mcp.md) for MCP configuration.

## Plugins

The `plugins` list in `config.json` loads your plugins, in order. An entry is a local folder or a Git repository:

```json
{
  "plugins": [
    "./plugins/hello",
    { "git": "https://github.com/lostcoords/yuke-plugins", "folder": "plugins/vim" }
  ]
}
```

Use `/plugins` in the terminal UI or `yuke plugin add` to add a plugin. See [Plugins](plugins.md) for the entry keys, the plugin commands, and the bundled plugins.
