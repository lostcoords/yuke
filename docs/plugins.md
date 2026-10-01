# Plugins

A plugin is `{ name, apply(ctx) }`. Register it with `plugins.use(plugin)`. Names are unique. Search `class Context` in `yuke.d.ts` for the exact lifecycle API.

## Lifecycle

| Member | Use |
|---|---|
| `ctx.effect(fn)` | Run `fn` now. Own the synchronous cleanup that it returns. |
| `ctx.own(release)` | Own a resource until unload. `release` can be async. |
| `ctx.signal` | Pass plugin cancellation to `fetch`, `exec`, or sockets. |
| `ctx.alive` | Check it after an `await` before you change plugin state. |
| `ctx.use(plugin)` | Start a child plugin that unloads with its parent. |

Register listeners, hooks, tools, and capabilities in the synchronous part of `apply`. yuke does not wait before it continues startup when `apply` is async. An unload cancels the signal, removes registrations, and releases resources from newest to oldest.

[`examples/herdr.js`](examples/herdr.js) is a complete lifecycle example. It uses a TUI injection, event listeners, cancellable Unix-socket I/O, bounded retries, and an async release. It stays inactive unless Herdr supplies its three environment variables. It also stays inactive when `AI_AGENT` or `CLAUDECODE` shows that another agent started yuke, because that agent holds the pane.

## Startup order

The TUI and `yuke check` start the bundled plugins, then the `prompt` plugin, then `index.js`, then the built-in tools. A profile can replace a bundled plugin. A model tool from `index.js` replaces a built-in tool with the same name.

`yuke -p` and `yuke --rpc` start no bundled plugin and provide no `tui` capability. See [Profile](profile.md#modes).

## Events

Search `interface EventsBase` in `yuke.d.ts` for public event names and listener arguments.

```js
ctx.on("run.done", (drain) => {
  if (drain.type === "session") {
    ctx.interaction.notify("run ended in " + drain.session);
  }
});
```

- Use `ctx.on` or `ctx.once` in a plugin. The context removes its listener at unload.
- Use `events.on` only when you own and call the returned disposer yourself.
- `events.emit` calls all listeners. `events.bail` asks the newest listener first and returns the first answer that is not `false`, `null`, or `undefined`.
- Event dispatch is synchronous. It does not await a promise from a listener. Catch failures and check lifecycle when a listener starts async work.
- Name a custom event `<plugin>:<name>`. See [Types](types.md#custom-events).

### Job changes

`job.changed` receives one `Job` with its `id`, `command`, `state`, and times. It fires when a job starts, when a stop request reaches the job, and when the job ends. Call `jobs.list()` from `"yuke"` to read all jobs.

### Engine drains

Engine fact events include `run.started`, `run.done`, `message.*`, and `tool.*`. Each receives the whole coalesced drain, not one fact payload. A session drain has `type: "session"`, a `session` ID, and a `facts` list. `engine.drained` receives every drain. Search `DrainFact`, `EngineEvent`, and `declare namespace $client` for exact types and queries.

Engine drains exist in every mode. UI input, pane, region, composer, and chat events require the TUI composition. A higher-level event such as `activity.changed` belongs to a bundled plugin and needs that plugin or a compatible replacement.

Use an [engine hook](engine.md#engine-hooks) when async work must block, replace, or approve an engine action.

## Capabilities

A capability shares a service between plugins:

```js
ctx.provide("counter", { count: () => 1 });
ctx.inject(["counter"], (c) => { c.counter.count(); });
```

An injection runs only while all named capabilities exist. It reverts and runs again when a provider changes. A provider with `bindTo(ctx)` builds one value for each injection block. That block owns what the value registers.

Public capabilities are `tui`, `chat`, and `composer-vim`. The last one exists only while the optional `composerVim` plugin runs. See [Types](types.md#custom-capabilities) for a custom capability.

## Advice

`ctx.advise(obj, "method", where, fn, options?)` changes one method for the plugin lifetime.

| `where` | Handler input | Handler result |
|---|---|---|
| `before`, `after` | method arguments | ignored |
| `around` | `next`, then arguments | method result; call `next(...args)` for the original |
| `filterArgs` | argument array | new arguments, or `undefined` to keep them |
| `filterReturn` | result | new result, or `undefined` to keep it |

`this` is the advised object. Common targets are `ChatView.prototype` and `Session.prototype`. Prefer advice or an event over a full replacement.

## Bundled plugins

Only the TUI and `yuke check` load these plugins. They start in table order. The ownership descriptions marked **implementation-specific** help estimate replacement work. They are not public APIs beyond the declarations.

| Bundled plugin | Current ownership |
|---|---|
| `keys` | Global navigation and process keys; pending-key status. **Implementation-specific.** |
| `toasts` | Notification toasts, history, and dismiss/history commands. **Implementation-specific.** |
| `command-ui` | Slash completion and the command palette. **Implementation-specific.** |
| `catalog` | Provider catalog loading and `/reload-providers`. **Implementation-specific.** |
| `auth` | Provider login and logout UI. **Implementation-specific.** |
| `jobs-ui` | Background-job status and `/jobs`. **Implementation-specific.** |
| `sessions` | `Session` integration, current-pane tracking, feed state, session/model commands, and model status. |
| `transcript` | The default transcript renderer. **Implementation-specific.** |
| `chat` | The `chat` capability, renderer stack, default `ChatView`, chat commands, attachments, and vision warnings. |
| `indicator` | The active-run rule in each chat pane. **Implementation-specific.** |
| `queue` | Queued-input strip and queue commands. **Implementation-specific.** |
| `context` | Context-usage status and `/context`. **Implementation-specific.** |
| `cache` | Prompt-cache usage UI. **Implementation-specific.** |
| `quit-guard` | The active-work quit check. **Implementation-specific.** |
| `shell` | Root pane creation, splits, focus, close, and window keys. |

Dispose the smallest owner, then install a replacement:

```js
plugins.dispose("chat");
plugins.use(myChatPlugin);
```

`plugins.dispose` returns a promise only when close waits for async work. A closing plugin keeps its name until that promise settles. The bundled plugins close synchronously during profile startup.

A replacement recreates each feature that it wants to preserve:

- A `chat` replacement provides `chat`. Extend `ChatSurface` to keep `render` and `refresh`, and override `create(session)`. Recreate `chat:new`, image paste, expand-all, and vision warnings when needed.
- A `transcript` replacement registers a default look with `c.chat.render`. See [Transcript](ui.md#transcript).
- A `sessions` replacement recreates focus tracking, session/model commands, status, and higher-level events that consumers need.
- A `command-ui` replacement recreates slash completion and the palette.
- A `shell` replacement creates and closes panes. It also supplies window commands and keys.
- Any other replacement recreates the commands or UI listed in its table row.

Do not import bundled implementations from `yuke:internal/*`. [`examples/roomy-chat.js`](examples/roomy-chat.js) is a complete `chat` replacement.

## Chat and editing APIs

Search `class ChatView`, `class ChatSurface`, `class Session`, `class Transcript`, `class Composer`, `class TextInput`, and `declare namespace $session` for exact signatures.

| API | Common public members |
|---|---|
| `ChatView` | `session`, `transcript`, `composer`, `focus`, `focusRegion`, `layout`, `draw` |
| `ChatSurface` | `create`, `render`, `refresh`; extend it when you replace the chat pane |
| `Session` | `sessionId`, `views`, `activity`, `open`, `send`, `interrupt`, `reload`, `join`, `leave` |
| `Transcript` | `pager`, `selection`, `messages`, `messageCount`, `rows`, `select`, `selectedText`, `activate` |
| `Composer` | `input`, `text`, `content`, `snapshot`, `restore`, `submit`, `hasImages` |
| `TextInput` | `text`, `caret`, `setText`, `replace`, `insert`, `beforeCaret` |
| `currentPane()` | The session pane that most recently had focus, or `null`. Its `composer` is optional. |
| `currentSession()` | The `Session` of `currentPane()`, or `null`. |
| `currentEntry()` | The current engine feed item with live activity, or `null`. Treat it as borrowed read-only state. |

The shell owns panes. A `ChatView` joins its `Session` when constructed. The sessions layer makes a closing pane leave. The last view releases the engine pin and removes the session from `sessions`. A pane owns its `Transcript`, `Composer`, and `TextInput`. The `current*` accessors return borrowed live objects; call them again after focus or session changes. Do not release those objects or keep them after `pane.closed` or plugin unload.

Read or change the draft:

```js
import { currentPane } from "yuke:session";

const input = currentPane()?.composer?.input;
if (input) {
  const oldText = input.text;
  input.insert(oldText === "" ? "Please " : "\nPlease ");
  // input.setText("replacement draft");
}
```

Observe the current pane:

```js
import { currentPane } from "yuke:session";

ctx.inject(["tui"], () => {
  ctx.on("pane.focused", () => {
    const pane = currentPane();
    const id = pane?.session.sessionId ?? "new draft";
    ctx.interaction.notify("focused " + id);
  });
});
```

These accessors need the bundled `sessions` plugin or a compatible replacement. They return `null` in headless modes. See [`examples/chat-api.js`](examples/chat-api.js) and [Vim](vim.md).
