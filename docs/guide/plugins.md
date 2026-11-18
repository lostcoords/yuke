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
| `path` | — | A folder with a `plugin.json`, the manifest that names the plugin and its entry module. A relative path starts in the profile folder. |
| `git` | — | The URL of a Git repository, as `git` takes it. |
| `folder` | The repository root | The plugin folder in the repository. It cannot be absolute or contain `..`. |
| `ref` | The default branch | The branch, tag, or commit to follow. |
| `options` | — | The options of the plugin. Each plugin defines and checks its own options. |

### Git plugins

yuke only loads installed plugins, and it never downloads a plugin at startup. If you add a Git plugin to `config.json` by hand, run `yuke plugin sync` or use `/plugins` in the terminal UI to install it.

Manage Git plugins with these commands, or with `/plugins`:

| Command | Description |
|---|---|
| `yuke plugin add URL` | Add a Git plugin to `config.json`, install it, and lock its commit in `plugins.lock`. `--folder` and `--ref` select the folder and the ref. |
| `yuke plugin remove NAME` | Remove a plugin from `config.json` and `plugins.lock`. Its files stay on disk. |
| `yuke plugin list` | Show each plugin, its locked commit, and whether it is installed. It uses no network. |
| `yuke plugin sync` | Install the locked commits, and lock each Git plugin that you added by hand. With `--locked`, fail instead when `plugins.lock` does not match `config.json`. |
| `yuke plugin update NAME...` | Show the new commits of each plugin's ref, and ask before it moves the lock. `--all` updates every Git plugin, and `--yes` skips the question. |

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

### Replace a bundled plugin

To replace a bundled plugin, disable its name and add your replacement. A replacement must provide the services that its consumers require. It must also supply the behavior that you want to keep. Do not import `yuke:internal/*`.

UI plugins return when `ctx.get("tui")` is `undefined`. The session API itself does not depend on the bundled `sessions` plugin.

## Entry points

The entry module exports named `apply`, named `session`, or both:

| Export | Scope | Context |
|---|---|---|
| `apply(ctx)` | Once per runtime | `PluginContext` from `yuke:plugins` |
| `session(s)` | Once per open session | `SessionContext` from `yuke:plugins` |
| `optionsSchema` | Validates plugin options | `ObjectSchema` from `yuke:tools` |

Use `apply` for services, host listeners, and UI. Use `session` for model tools, engine hooks, and session jobs. A plugin that needs no code can omit its entry module.

Without `optionsSchema`, a plugin accepts no options. With a schema, use `Infer<typeof optionsSchema>` from `yuke:tools` as the type parameter of both contexts. The host validates and freezes the options before setup.

The loader awaits each `apply` in load order. Each `session` setup starts before any of the setups settles. Opening a session does not wait for setup. The first request for its tools waits for setup.

## Lifecycle

Both entry functions can return `undefined` or a cleanup function. They can also return a promise for either value. Cleanup can be async.

This entry module returns cleanup for a host listener:

<<< @/guide/examples/lifecycle.js

`ctx.signal` aborts when the plugin fails to load or the runtime closes. `s.signal` aborts when the session closes or that plugin's session setup fails. Pass the appropriate signal to I/O. Stop timers and other work in cleanup. A setup that awaits work must end when its signal aborts.

Session close stops plugin jobs, aborts session signals, and awaits setup, cleanup, and job work. Runtime close then aborts plugin signals and awaits `apply` cleanup in reverse plugin order. A cleanup failure sends a notice and does not prevent the other cleanups.

A failed `session` setup removes that plugin's tools and hooks from the session. It does not remove the other plugins' registrations.

Module state lasts for one runtime. Use `ctx.dataDir` for files that must survive reload. Use `import.meta.dirname` for files beside a file-based entry module.

## Services

A service shares a typed value between plugins. The provider declares its name in `provides` and publishes it with `ctx.provide(name, value)` during `apply`. A consumer declares the name in `uses` and reads it with `ctx.get(name)`.

The loader applies providers before consumers. It rejects missing providers, duplicate providers, and cycles. A plugin does not load when a provider that it uses failed to load. A service provider adds its type to the `Services` interface of `yuke:plugins`.

Three services need no `uses` entry:

| Service | Value |
|---|---|
| `tui` | This plugin's terminal interface, or `undefined` outside the TUI. |
| `sessions` | Session creation, queries, and handles in every mode. |
| `catalog` | Provider and model queries in every mode. |

The bundled `chat` plugin provides the `chat` service. A consumer of `chat` needs a `uses` entry. A declared plugin service is present after its provider loads; it is not an optional `null` result.

## Events

`ctx.addListener(event, listener)` observes a host fact and returns a remover. The plugin signal also removes the listener.

| Event | Data |
|---|---|
| `session.opened` | `sessionId`, `parent` (when the session has one), `state`, the running `jobs`, and the open question IDs in `interactions` |
| `session.update` | `sessionId` and `update` |
| `session.closed` | `sessionId` |
| `notice` | The notice: `level`, `source`, `text`, and `sessionId` when a session sent it |
| `catalog.changed` | No data. A login, a logout, or a credential changed the ready providers. |
| `theme.changed` | Theme `name` and terminal `background`. Only the terminal interface sends it. |

A `session.opened` listener first receives the sessions that are already open. A listener holds no session open. Event data is read-only. A `session.update` has a `kind`, such as `state`.

<<< @/snippets/plugins/events.ts

The host does not await listeners. A throw sends a notice, and the listener stays. Handle failures inside async work that a listener starts. Use an [engine hook](engine.md#engine-hooks) when work must block an action.

`ctx.sendClientEvent` and `s.sendClientEvent` send extension events to the active RPC client. They do not publish host facts to other plugins. With no client, the host drops the event.

## Find the API

The installer puts the public API of your release in `~/.local/lib/yuke`:

| Path | Content |
|---|---|
| `modules/plugins.ts` | `yuke:plugins`: `PluginContext`, `SessionContext`, `SessionHooks`, `HostEvents`, `Sessions`, and `SessionHandle`. |
| `modules/tools.ts` | `yuke:tools`: `ObjectSchema`, `Infer`, and `ToolExecuteResult`. |
| `types/*.d.ts` | The host modules: `yuke:tui`, `yuke:chat`, `yuke:ai`, `yuke:transcript`, `yuke:fs`, `yuke:net`, `yuke:process`, and `yuke:test`. |
| `protocol/` | The RPC protocol reference and its types. |
| `tsconfig.json` | The configuration that maps each `yuke:*` import to these files. |

The doc comments in these files describe each member. Do not import `yuke:internal/*`, and do not reach a missing name through a cast or `any`.

## Test and debug

Check the types against the profile configuration:

```sh
tsc -p ~/.config/yuke/tsconfig.json
```

Use your actual profile path if it differs. For behavior tests, run `yuke test` on `*.test.ts` files that use `yuke:test`. It runs the files that you name, or each such file below the current folder. A test uses an isolated app and a fake model. It does not need provider credentials. `types/test.d.ts` has the test API.

A type check does not verify terminal input or drawing. Start a separate terminal session to check those behaviors.

`/reload` reads the configuration, providers, and plugin files again. Wait for active turns to end before you reload. A reload replaces the JavaScript runtime, so module state resets. Process jobs continue, but plugin-owned jobs stop. A failed reload keeps the previous plugins and providers.

### Debug a plugin

Console output becomes a `notice` notification from the source `console`. Plugin notices and script faults also reach the active frontend. Inspect terminal notices or the `notice` messages of an RPC client. CLI startup errors go to stderr.

Capture stderr or protocol notifications when you need a record of a failure. Do not publish credentials or private task content in a diagnostic report.
