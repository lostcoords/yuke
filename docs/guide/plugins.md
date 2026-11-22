---
description: Install plugins, and write them with entry points, cleanup, services, and host events.
---

# Plugins

A plugin adds shared services, session behavior, or TUI parts. See [Your first plugin](first-plugin.md) for a small example.

## Install plugins

The `plugins` list in [`config.json`](config.md) loads your plugins, in order. Each entry is a local folder or a Git repository.

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

yuke never downloads a plugin at startup. For a Git plugin that you add to `config.json` by hand, run `yuke plugin sync` or use `/plugins` in the TUI.

A plugin that does not load does not stop the others. This covers a plugin that is not installed, has a bad `plugin.json`, or fails in its code. yuke loads the other plugins, and it gives one error notice. For one failed plugin, the notice reads "Plugin NAME did not load: REASON". For more plugins, it names them: "2 plugins did not load: a, b · /plugins or `yuke plugin list` shows why". `/plugins` shows why each one failed. A bad `config.json` or `plugins.lock` stops the start.

| Command | Description |
|---|---|
| `yuke plugin add URL [NAME...]` | Add the plugins of a Git repository to `config.json` by the names of their `plugin.json`, install them, and lock their commit in `plugins.lock`. yuke finds the folder of each one. A repository with one plugin needs no name. `--ref` selects the branch, tag, or commit to follow. |
| `yuke plugin remove NAME` | Remove a plugin from `config.json` and `plugins.lock`. Its files stay on disk. |
| `yuke plugin list` | Show each plugin and its state: local, installed at a commit, not installed, or failed with the reason. |
| `yuke plugin sync` | Install the locked commits, and lock each new Git plugin. If a plugin does not install, sync installs the others and then fails with the reason of each one. With `--locked`, fail instead when `plugins.lock` does not match `config.json`. |
| `yuke plugin update NAME...` | Show the new commits of each plugin's ref that change its folder, and ask before it moves the lock. If update cannot check a plugin, it updates the others and then fails with the reason of each one. `--all` updates every Git plugin, and `--yes` skips the question. Without `--yes`, it needs a terminal for the question. |

In the TUI, `/plugins` shows your plugins in three sections. **Needs attention** shows each plugin that is not installed or does not load, with the reason. **Git** and **Local** show the others. The state of a plugin is `loaded`, `reload loads it`, `failed`, or `not installed`.

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

yuke loads these plugins before yours. A bundled plugin adds the slash commands in the last column. See [Use the TUI](use.md) for the commands and the keys.

| Plugin | What it does | Options | Slash commands |
|---|---|---|---|
| `compaction` | Summarizes old context, in every mode. | — | — |
| `themes` | Loads and selects themes. | — | `/themes` |
| `chat` | Draws the chat panes and provides the `chat` service. | `emptyView`: boolean, default `true`. Set `false` to hide the header of an empty chat pane. | `/model`, `/new`, `/rename` |
| `sessions` | Browses saved sessions. | — | `/sessions` |
| `files` | Completes `@` file paths in a chat draft. | — | — |
| `bar` | Draws the status bar. | `hide` and `order`: lists of item keys, such as `"core:keys"`. | — |
| `toasts` | Shows notices and their history. | — | `/messages` |
| `login` | Connects providers from the TUI. | — | `/login`, `/logout` |
| `plugins` | Manages your plugins with the `/plugins` dashboard. | — | `/plugins` |

The TUI core adds `/quit` and `/reload`. These two do not belong to a plugin.

Use `disable` to turn off a bundled plugin, and `bundled` to give it options:

```json
{
  "disable": ["toasts"],
  "bundled": { "bar": { "hide": ["core:keys"] }, "chat": { "emptyView": false } }
}
```

A name in `disable` or `bundled` must be the name of a bundled plugin. Another name stops the start.

To replace a bundled plugin, disable its name and add your own plugin with the same name. Your plugin must provide the services that other plugins use from the old plugin. The bundled `sessions` and `files` plugins use the `chat` service. If you disable `chat`, provide a `chat` service, or disable `sessions` and `files` too.

## Plugin manifest

Each plugin folder has a `plugin.json`. yuke reads these fields:

```json
{
  "name": "notes",
  "extensions": {
    "sh.yuke": {
      "entry": "./index.ts",
      "uses": ["chat"],
      "provides": ["acme.notes.v1"]
    }
  }
}
```

| Field | Meaning |
|---|---|
| `name` | Required. One folder name: not empty, not `.` or `..`, and with no `/` or `\`. It is the source of the notices, the prefix of the commands, and the name of the data folder `plugins/<name>/`. |
| `extensions["sh.yuke"]` | Optional. The fields of yuke, below. |

| Field of `sh.yuke` | Meaning |
|---|---|
| `entry` | The entry module, as a path in the plugin folder. It is a `.ts` or a `.js` file. Without `entry`, the plugin has no code. |
| `uses` | The services that the plugin reads with `ctx.get`. See [Services](#services). |
| `provides` | The services that the plugin publishes with `ctx.provide`. |

A plugin can ship only a `skills` folder. Leave out `entry`, and the plugin adds the skills of its folder. See [AGENTS.md and skills](instructions.md#skills).

yuke ignores the other fields of `plugin.json` and the other keys of `extensions`. A field of `sh.yuke` that yuke does not know is an error, and the plugin does not load.

These rules make a plugin fail to load:

- The `name` is not a folder name.
- Another plugin has the same name. A bundled plugin has the same name, and it is not in `disable`.
- `provides` names `tui`, `sessions`, or `catalog`. These services belong to yuke.
- Another plugin provides a service of `provides` already.

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

A service shares a typed value between plugins.

- The provider names the service in `provides` in the `sh.yuke` extension of `plugin.json`.
- The provider publishes the value with `ctx.provide(name, value)` during `apply`.
- A consumer names the service in `uses`.
- The consumer reads the value with `ctx.get(name)`.
- The provider adds the type of its service to the `Services` interface of `yuke:plugins`.

yuke orders the plugins itself: it loads each provider before the plugins that use it. The order of the `plugins` list does not matter for services. A plugin does not load in these cases:

- No plugin provides a service that it uses.
- The provider of a service that it uses did not load.
- The `uses` of some plugins form a cycle.

Three services belong to yuke. No plugin can provide them, and a plugin must not list them in `uses`:

| Service | Value |
|---|---|
| `tui` | The TUI of this plugin, or `undefined` outside the TUI. |
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
| `theme.changed` | Theme `name` and terminal `background`. Only the TUI sends it. |

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

Check the types with `tsc -p ~/.config/yuke/tsconfig.json`. Use your actual profile path if it differs. See [Your first plugin](first-plugin.md) for the TypeScript version.

For behavior tests, run `yuke test` on `*.test.ts` files that use `yuke:test`:

```sh
yuke test [PATHS]...
```

`PATHS` are test files or folders. A folder gives each `*.test.ts` file below it. Without `PATHS`, yuke searches the current folder. A path to a file that is not a `*.test.ts` file is an error. The command fails when it finds no `*.test.ts` file, and when a test fails.

A test uses an isolated app and a fake model, and needs no provider credentials. `types/test.d.ts` has the test API.

`createHost` loads only the plugins that the test names. Give it a frame from `createFrame`, and each plugin gets a terminal on that frame. A bundled plugin of yuke, such as the chat, loads by its name:

```ts
import { assertEquals, createFrame, createHost, test } from "yuke:test";

test("the bar shows the mode of the plugin", async () => {
  using frame = createFrame({ width: 40, height: 3 });
  await using _host = await createHost({ frame, plugins: [{ bundled: "bar" }, { folder: "." }] });
  assertEquals(frame.rows().at(-1), "NORMAL");
});
```

Create the frame before the host, so that the host closes first. A frame test draws into a grid of cells with the default theme and no real terminal: start a TUI session to check the look in your terminal.

`/reload` reads the configuration, providers, and plugin files again. Wait for active turns to end first. A reload replaces the JavaScript runtime, so module state resets and plugin jobs stop. A bad `config.json`, `plugins.lock`, or `providers.json` fails the reload, and yuke keeps the previous plugins and providers.

Console output becomes a `notice` from the source `console`. The TUI shows it as a notice. An RPC client gets it in a `notice` JSON-RPC notification. CLI startup errors go to stderr.
