---
description: Set the folders and profiles for config, credentials, sessions, and plugins.
---

# Configuration

yuke keeps its files in these folders. yuke uses each XDG variable when it is set to an absolute path. Otherwise, it uses the default.

| Folder | Default | Contents |
|---|---|---|
| `$XDG_CONFIG_HOME/yuke` | `~/.config/yuke` | `config.json`, `providers.json`, `mcp.json`, `plugins.lock`, and your local plugins |
| `$XDG_DATA_HOME/yuke` | `~/.local/share/yuke` | Sessions, `auth.json`, `mcp-trust/`, `git/` (installed Git plugins), and `plugins/<name>/` |
| `$XDG_CACHE_HOME/yuke` | `~/.cache/yuke` | Files that yuke can create again, such as the JavaScript of your TypeScript plugins and the Git clones of plugins |
| `~/.local/lib/yuke` | `~/.local/lib/yuke` | The installed release: the public TypeScript API, the protocol bindings, these guides, and the agent skill |

Each plugin has its own data folder, `plugins/<name>/` in the data folder. A plugin reads its path from `ctx.dataDir`, and the folder stays across reloads. The bundled `chat` plugin keeps your last model choice in `plugins/chat/choice.json`. The bundled `themes` plugin keeps the selected theme in `plugins/themes/theme.json`.

## Profiles

Set `YUKE_APPNAME` to use another profile:

```sh
YUKE_APPNAME=yuke-work yuke
```

This profile uses `~/.config/yuke-work`, `~/.local/share/yuke-work`, and `~/.cache/yuke-work`. An empty value gives `yuke`. yuke does not check the name, so use a plain folder name. The installer writes the `tsconfig.json` of the editor into the config folder of the same variable.

## config.json

`config.json` accepts JSON with `//` and `/* */` comments. A missing file uses the defaults. An unknown field, a bad value, or a JSON error stops startup, and the error names the file.

| Key | Default | Description |
|---|---|---|
| `plugins` | `[]` | Your plugins: local folders or Git repositories. See [Plugins](#plugins). |
| `disable` | `[]` | [Bundled plugins](plugins.md#bundled-plugins) to turn off, by name, such as `["toasts"]`. |
| `bundled` | `{}` | Options for [bundled plugins](plugins.md#bundled-plugins), by name. |
| `sessionIdleMinutes` | `30` | How long background jobs keep running in a session that no view or client has open. After this time, yuke closes the session and stops its jobs. |

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

Use `/plugins` in the TUI or `yuke plugin add` to add a plugin. See [Plugins](plugins.md) for the entry keys, the plugin commands, and the bundled plugins.

## Environment variables

| Variable | Use |
|---|---|
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` | Move the folders in the table above. |
| `YUKE_APPNAME` | Select another [profile](#profiles). |
| `ANTHROPIC_API_KEY` and the other variables of [Providers](providers.md#credentials) | Give a provider an API key. |
| `SSL_CERT_FILE`, `SSL_CERT_DIR` | Name the root certificates. See [Network](providers.md#network). |
| `COLORTERM` | The values `truecolor` and `24bit` turn on 24-bit colors in the TUI. See [Themes](themes.md#palette). |

yuke reads no proxy variable. See [Network](providers.md#network).
