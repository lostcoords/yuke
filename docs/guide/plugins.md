---
description: Write plugins with runtime and session entry points, cleanup, typed services, and host facts.
---

# Plugins

A plugin adds shared services, session behavior, or terminal UI. Its manifest names the plugin and its entry module. See [Profile](profile.md) for installation and [Your first plugin](first-plugin.md) for a small example.

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

## Contexts

| `PluginContext` member | Use |
|---|---|
| `name` | Read the plugin name. |
| `dataDir` | Read the absolute, persistent data folder. |
| `options` | Read validated, deeply frozen options. |
| `signal` | Observe plugin shutdown. |
| `get`, `provide` | Use or publish a service. |
| `on` | Observe a host fact. |
| `notify(level, message)` | Send a notice with this plugin as its source. |
| `emit(event, data?)` | Send a plugin extension event to an RPC client. |

`SessionContext` supplies `sessionId`, `parent`, `folder`, `settings`, `options`, and `signal`. Each read of `settings` gives a frozen copy of the current session settings. `parent` is `undefined` for a session without a parent.

Its operations are `tools.define`, `hook`, `jobs.run`, `notify`, `emit`, `ask`, and `request`. See [Tools](tools.md) and [Engine](engine.md). Capture a shared service in `apply` when the session code needs it.

## Services

A service shares a typed value between plugins. The provider declares its name in `provides` and publishes it with `ctx.provide(name, value)` during `apply`. A consumer declares the name in `uses` and reads it with `ctx.get(name)`.

The loader applies providers before consumers. It rejects missing providers, duplicate providers, and cycles. A service provider adds its type to the `Services` interface of `yuke:plugins`. See [Types](types.md) for module augmentation.

Four services need no `uses` entry:

| Service | Value |
|---|---|
| `tui` | This plugin's terminal interface, or `undefined` outside the TUI. |
| `sessions` | Session creation, queries, and handles in every mode. |
| `catalog` | Provider and model queries in every mode. |
| `plugins` | The profile plugin manager in every mode. |

The bundled `chat` plugin provides the `chat` service. A consumer of `chat` needs a `uses` entry. A declared plugin service is present after its provider loads; it is not an optional `null` result.

## Events

`ctx.on(event, listener)` observes a host fact and returns a remover. The plugin signal also removes the listener.

| Event | Data |
|---|---|
| `session.opened` | `sessionId`, `state`, and open question IDs in `questions` |
| `session.update` | `sessionId` and `update` |
| `session.closed` | `sessionId` |
| `notice` | The notice, including its source and message |
| `theme.changed` | Theme `name` and terminal `background` |

A `session.opened` listener first receives the sessions that are already open. A listener holds no session open. Event data is read-only.

<<< @/snippets/plugins/events.ts

The host does not await listeners. A synchronous throw removes the listener and sends a notice. Handle failures inside async work that a listener starts. Use an [engine hook](engine.md#engine-hooks) when work must block an action.

`ctx.emit` and `s.emit` send extension events to the active RPC client. They do not publish host facts to other plugins. With no client, the host drops the event.

## Browse and open sessions

Get the service with `ctx.get("sessions")`.

- `list(params?)` returns a page with `sessions` and an optional `nextCursor`. Pass that cursor as `cursor` for the next page. Keep the same filters.
- `get(id)` returns the saved row with current activity.
- `events(id, { limit, before? })` reads saved events without an open handle.
- `open(id, { tail, event, signal? })` returns a `SessionHandle` after it delivers the initial snapshot. Later calls to `event` receive updates.

A list without `parent` contains sessions without a parent. Set `parent` to list that session's children. Set `cwd` to filter by the current session folder.

An open handle holds a session open. Abort the signal passed to `open` to release that handle. Other handles remain valid. `sessions.close(id)` instead closes the session for every holder and stops its jobs.

A handle supplies `input`, `sendNotification`, `cancel`, `idle`, `setSettings`, and other session operations. See the `SessionHandle` declaration in [Types](types.md). `idle()` waits for accepted input to be handled; it does not prove that the turn succeeded. A terminal saved commit records its outcome in `end`.

For terminal panes and drafts, use the public `chat` service. See [UI](ui.md).

## Bundled plugins

The default plugin order is:

| Plugin | Purpose |
|---|---|
| `compaction` | Summarize old context through session hooks in every mode. |
| `themes` | Load and select terminal themes. |
| `chat` | Provide chat panes and the `chat` service. |
| `sessions` | Browse saved sessions and show one in a chat pane. |
| `bar` | Draw the terminal status bar. |
| `toasts` | Show notices and their history. |
| `plugins` | Manage profile plugins through terminal commands and a dashboard. |

UI plugins return when `ctx.get("tui")` is `undefined`. The session API itself does not depend on the bundled `sessions` plugin.

To replace a bundled plugin, disable its name in the [profile](profile.md) and add your replacement. A replacement must provide the services that its consumers require. It must also supply the behavior that you want to preserve. Do not import `yuke:internal/*`.
