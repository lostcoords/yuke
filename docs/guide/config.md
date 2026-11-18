---
description: Set the folders and profiles for config, credentials, sessions, and plugins.
---

# Configuration

yuke keeps its files in these folders. yuke uses each XDG variable when it is set to an absolute path. Otherwise, it uses the default.

| Folder | Default | Contents |
|---|---|---|
| `$XDG_CONFIG_HOME/yuke` | `~/.config/yuke` | `config.json`, `providers.json`, `mcp.json`, `plugins.lock`, and your local plugins |
| `$XDG_DATA_HOME/yuke` | `~/.local/share/yuke` | Sessions, `auth.json`, `choice.json`, `mcp-trust`, and installed Git plugins |
| `$XDG_CACHE_HOME/yuke` | `~/.cache/yuke` | Files that yuke can create again |
| `~/.local/lib/yuke` | `~/.local/lib/yuke` | The installed release: the public TypeScript API, the protocol bindings, these guides, and the agent skill |

## Profiles

Set `YUKE_APPNAME` to use another profile:

```sh
YUKE_APPNAME=yuke-work yuke
```

This profile uses `~/.config/yuke-work`, `~/.local/share/yuke-work`, and `~/.cache/yuke-work`. The name must be a plain folder name.

## config.json

`config.json` accepts JSON with `//` and `/* */` comments. A missing file uses the defaults. An unknown field, a bad value, or a JSON error stops startup, and the error names the file.

| Key | Default | Description |
|---|---|---|
| `plugins` | `[]` | Your plugins: local folders or Git repositories. See [Plugins](#plugins). |
| `disable` | `[]` | [Bundled plugins](plugins.md#bundled-plugins) to turn off, by name, such as `["toasts"]`. |
| `bundled` | `{}` | Options for [bundled plugins](plugins.md#bundled-plugins), by name. |
| `sessionIdleMinutes` | `30` | How long background jobs keep running in a session that no pane or client has open. After this time, yuke closes the session and stops its jobs. |

## Plugins

The `plugins` list loads your plugins, in order. An entry is a local folder or a Git repository:

```json
{
  "plugins": [
    "./plugins/hello",
    { "git": "https://github.com/lostcoords/yuke-plugins", "folder": "plugins/vim" }
  ]
}
```

Use `/plugins` in the terminal UI or `yuke plugin add` to add a plugin. See [Plugins](plugins.md) for the entry keys, the plugin commands, and the bundled plugins.
