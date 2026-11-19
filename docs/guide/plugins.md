---
description: Install plugins, and write them with entry points, cleanup, services, and host events.
---

# Plugins

A plugin adds shared services, session behavior, or terminal UI. See [Your first plugin](first-plugin.md) for a small example.

## Install plugins

The `plugins` list in [`config.json`](config.md#configjson) loads your plugins, in order. Each entry is a local folder or a Git repository.

```json
{
  "plugins": [
    "./plugins/hello",
    { "path": "./plugins/my-plugin", "options": { "greeting": "hi" } },
    { "git": "https://github.com/lostcoords/yuke-plugins", "folder": "plugins/vim" }
  ]
}
```

An entry is a path, or an object with `path` or `git`:

| Key | Default | Description |
|---|---|---|
| `path` | — | A folder with a `plugin.json`. A relative path starts in the profile folder. |
| `git` | — | The URL of a Git repository, as `git` takes it. |
| `folder` | The repository root | The plugin folder in the repository. |
| `ref` | The default branch | The branch, tag, or commit to follow. |
| `options` | — | The options of the plugin. |

yuke never downloads a plugin at startup. For a Git plugin that you add to `config.json` by hand, run `yuke plugin sync` or use `/plugins` in the terminal UI.

A plugin that does not load does not stop the others. This covers a plugin that is not installed, has a bad `plugin.json`, or fails in its code. yuke loads the other plugins and gives one notice that names the failed plugins. `/plugins` shows why each one failed. A bad `config.json` or `plugins.lock` stops the start.

| Command | Description |
|---|---|
| `yuke plugin add URL [NAME...]` | Add the plugins of a Git repository to `config.json` by the names of their `plugin.json`, install them, and lock their commit in `plugins.lock`. yuke finds the folder of each one. A repository with one plugin needs no name. `--ref` selects the branch or tag to follow. |
| `yuke plugin remove NAME` | Remove a plugin from `config.json` and `plugins.lock`. Its files stay on disk. |
| `yuke plugin list` | Show each plugin and its state: local, installed at a commit, not installed, or failed with the reason. |
| `yuke plugin sync` | Install the locked commits, and lock each new Git plugin. With `--locked`, fail instead when `plugins.lock` does not match `config.json`. |
| `yuke plugin update NAME...` | Show the new commits of each plugin's ref, and ask before it moves the lock. `--all` updates every Git plugin, and `--yes` skips the question. |

In the terminal UI, `/plugins` shows your plugins in three sections. **Needs attention** shows each plugin that is not installed or does not load, with the reason. **Git** and **Local** show the others. The state of a plugin is `loaded`, `reload loads it`, `failed`, or `not installed`.

| Key | Action |
|---|---|
| `s` | Install each Git plugin that is not installed. |
| `c` | Check each Git plugin for new commits, and show them before the update. |
| `u` | Check the selected Git plugin for new commits. |
| `a` | Add a plugin. Paste the URL of a Git repository, and select a plugin when the repository has more. |
| `d` | Remove the selected plugin. Its files stay on disk. |
| `r` | Reload, so the changes load. |

A plugin runs with your user rights. Read its source before you install it.

## Bundled plugins

yuke loads these plugins before yours:

| Plugin | What it does | Options |
|---|---|---|
| `compaction` | Summarizes old context, in every mode. | — |
| `themes` | Loads and selects terminal themes. | — |
| `chat` | Draws the chat panes and provides the `chat` service. | — |
| `sessions` | Browses saved sessions. | — |
| `files` | Completes `@` file paths in a chat draft. | — |
| `bar` | Draws the status bar. | `hide` and `order`: lists of item keys, such as `"core:keys"`. |
| `toasts` | Shows notices and their history. | — |
| `login` | Connects providers from the terminal UI with `/login` and `/logout`. | — |
| `plugins` | Manages your plugins with the `/plugins` dashboard. | — |

Use `disable` to turn off a bundled plugin, and `bundled` to give it options:

```json
{
  "disable": ["toasts"],
  "bundled": { "bar": { "hide": ["core:keys"] } }
}
```

To replace a bundled plugin, disable its name and add your own. Your plugin must provide the services that consumers of the old plugin use.

## Entry points

The entry module of a plugin exports `apply`, `session`, or both:

| Export | Scope | Context |
|---|---|---|
| `apply(ctx)` | Once per runtime | `PluginContext` from `yuke:plugins` |
| `session(s)` | Once per open session | `SessionContext` from `yuke:plugins` |
| `optionsSchema` | Validates plugin options | `ObjectSchema` from `yuke:tools` |

Use `apply` for services, host listeners, and UI. Use `session` for model tools, engine hooks, and session jobs.

Without `optionsSchema`, a plugin accepts no options. With a schema, use `Infer<typeof optionsSchema>` from `yuke:tools` as the type parameter of both contexts. The host validates and freezes the options before setup.

Opening a session does not wait for `session`. The first request for its tools waits.

## Lifecycle

Both entry functions can return a cleanup function, or a promise for one. This entry module returns cleanup for a host listener:

<<< @/guide/examples/lifecycle.js

`ctx.signal` aborts when the plugin fails to load or the runtime closes. `s.signal` aborts when the session closes or that plugin's `session` fails. Pass the signal to I/O, and stop timers in cleanup.

Session close runs the `session` cleanups. Runtime close then runs the `apply` cleanups, last plugin first. A failed cleanup sends a notice and does not stop the others. A failed `session` setup removes only that plugin's tools and hooks from the session.

Module state lasts for one runtime. Use `ctx.dataDir` for files that must survive a reload.

## Services

A service shares a typed value between plugins. The provider names the service in `provides` in the `sh.yuke` extension of `plugin.json`, and publishes it with `ctx.provide(name, value)` during `apply`. A consumer names it in `uses` and reads it with `ctx.get(name)`. The loader loads providers first. A plugin does not load when another plugin before it provides the same service, or when no plugin before it provides a service that it uses. A cycle of uses has the same result. A provider adds the type of its service to the `Services` interface of `yuke:plugins`.

Three services need no `uses` entry:

| Service | Value |
|---|---|
| `tui` | This plugin's terminal interface, or `undefined` outside the TUI. |
| `sessions` | Session creation, queries, and handles in every mode. |
| `catalog` | Provider and model queries in every mode. |

The bundled `chat` plugin provides the `chat` service. A consumer of `chat` needs a `uses` entry.

## Events

`ctx.addListener(event, listener)` observes a host fact and returns a remover. The plugin signal also removes the listener.

| Event | Data |
|---|---|
| `session.opened` | `sessionId`, `parent`, `state`, `jobs`, and `interactions` |
| `session.update` | `sessionId` and `update` |
| `session.closed` | `sessionId` |
| `notice` | `level`, `source`, `text`, and `sessionId` |
| `catalog.changed` | No data. A login, a logout, or a credential changed the ready providers. |
| `theme.changed` | Theme `name` and terminal `background`. Only the terminal interface sends it. |

A `session.opened` listener first receives the sessions that are already open. A `session.update` has a `kind`, such as `state`.

<<< @/snippets/plugins/events.ts

The host does not await listeners. A throw sends a notice, and the listener stays. Use an [engine hook](engine.md#engine-hooks) when work must block an action.

## Find the API

The installer puts the public API of your release in `~/.local/lib/yuke`:

| Path | Content |
|---|---|
| `modules/*.ts` | `yuke:plugins` (`PluginContext`, `SessionContext`, `SessionHooks`, `HostEvents`, `Sessions`), `yuke:tools`, and `yuke:protocol`. |
| `types/*.d.ts` | The host modules: `yuke:tui`, `yuke:chat`, `yuke:ai`, `yuke:transcript`, `yuke:fs`, `yuke:net`, `yuke:process`, and `yuke:test`. |
| `protocol/` | The RPC protocol reference and its types. |
| `tsconfig.json` | The configuration that maps each `yuke:*` import to these files. |

The doc comments in these files describe each member. Do not import `yuke:internal/*`.

## Test and debug

Check the types with `tsc -p ~/.config/yuke/tsconfig.json`. Use your actual profile path if it differs.

For behavior tests, run `yuke test` on `*.test.ts` files that use `yuke:test`. A test uses an isolated app and a fake model, and needs no provider credentials. `types/test.d.ts` has the test API. A type check or a test does not show how the terminal draws: start a terminal session to check that.

`/reload` reads the configuration, providers, and plugin files again. Wait for active turns to end first. A reload replaces the JavaScript runtime, so module state resets and plugin jobs stop. A bad `config.json`, `plugins.lock`, or `providers.json` fails the reload, and yuke keeps the previous plugins and providers.

Console output becomes a `notice` from the source `console`. A terminal shows it as a notice, and an RPC client gets it as a `notice` notification. CLI startup errors go to stderr.
