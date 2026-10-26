# Plugins

A plugin is a folder that `config.json` lists. Its `plugin.json` names it and declares `uses` and `provides`, and its entry exports `apply(ctx)`. See [Profile](profile.md#a-plugin). Names are unique. Search `class Context` in `yuke.d.ts` for the exact lifecycle API.

## Lifecycle

| Member | Use |
|---|---|
| `ctx.effect(fn)` | Run `fn` now. Own the synchronous cleanup that it returns. |
| `ctx.own(release)` | Own a resource until unload. `release` can be async. |
| `ctx.signal` | Pass plugin cancellation to `fetch`, `exec`, or sockets. |
| `ctx.alive` | Check it after an `await` before you change plugin state. |
| `ctx.root` | The plugin folder. Read the files of the plugin from it. |

`ctx.resources(name)` creates an owned resource lifetime for a dialog or request. It supplies `alive`, `signal`, `effect`, `own`, and `dispose`. Its disposal cancels I/O, removes effects, and waits for releases. The parent plugin stays loaded. Plugin unload closes remaining resource owners. A disposed owner rejects new registrations. It cannot load plugins or register tools or capabilities.

`apply` must return nothing, or a promise that resolves to `undefined`. A resource or another resolved value fails the plugin. Register cleanup with `ctx.own`; do not return the resource. Startup waits for each async `apply` before it starts the next plugin. A slow `apply` delays startup, so start long work without `await`.

No module state survives a [reload](profile.md#check-a-change). Keep state that must survive in a file.

[`examples/lifecycle.js`](examples/lifecycle.js) owns a timer with `ctx.effect` and a child process with `ctx.own`. Its command passes `ctx.signal` to I/O and checks `ctx.alive` after the wait. It runs in the TUI and in `yuke check`; the check starts and stops the child too.

### Unload order

1. Mark the plugin dead and cancel its signal.
2. Remove its effects and registrations, newest first.
3. Release its resources, newest first. Wait for each async release before the next release.
4. Wait for canceled I/O to finish.

An event listener does not keep the plugin alive across an `await`. Catch its async failures. Check `ctx.alive` before changing state or registering another effect. See [Reload](profile.md#check-a-change) for what survives runtime replacement.

`ctx.inspectPlugins()` returns owned name and closing-state records for current plugin owners. It runs no handlers. Query it only on inspection paths, not during draw or stream delivery.

## Startup order

To remove a profile plugin, remove its folder from `plugins` in `config.json`. Run `/reload` to apply the change. A plugin cannot load or close another plugin.

Startup loads the bundled plugins, the `prompt` plugin, the built-in tools, and the plugins of `config.json` in one pass. The loader applies each provider before each plugin that uses its capability. Other plugins keep that order. A profile model tool cannot take the name of a built-in tool.

See [Modes](profile.md#modes) for which plugins and capabilities each frontend loads.

`apply` can create a session or start a run. That session and that run see the tools and hooks of the plugins that registered them before, and the skills of the plugins that their workspace activates. A question in `apply` gets the answer of `yuke -p`, because no frontend reads input yet. Ask from a command or an event.

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

Engine fact events include `run.started`, `run.done`, `message.*`, and `tool.*`. Each receives the whole coalesced drain, not one fact payload. `engine.drained` receives the session and index drains. Search `DrainFact`, `EngineEvent`, and `declare namespace $client` for exact types and queries.

| `type` | Fields and action |
|---|---|
| `"session"` | `session`, `kind`, `facts`, optional `id` and `part`. Re-read the named session. |
| `"index"` | `overflow`, `facts`, optional `auth` and `notices`. No session ID. Refresh the session list; an overflow also needs a full refresh of session state. |
| `"activity"` | Internal activity wakeup. Plugin listeners use `engine.activity.changed`, which has no payload, and re-read `client.load()`. |

```js
import { client } from "yuke";

ctx.on("run.done", (drain) => {
  if (drain.type === "index") {
    ctx.print(drain.overflow ? "refresh the index and all session state" : "refresh the index");
    return;
  }
  const activity = client.sessionActivity(drain.session);
  ctx.print({ session: drain.session, kind: drain.kind, activity });
});
```

This completion listener shows the branch and one public query. Do not log or query the whole session on every streamed change. A browser must also handle its index and session changes and update its own list or transcript. Do not treat `facts` as a list of notification payloads. Repeated facts can merge into one name. Two changed parts can remove `part`; two changed messages can change `kind` to `"reload"` and remove `id`. The optional IDs describe transcript refresh work, not each fact. A timer or tool tracker must re-read public state instead of assigning all facts to one ID.

Engine drains exist in every mode. UI input, pane, region, composer, and chat events require the TUI composition. A higher-level event such as `activity.changed` belongs to a bundled plugin and needs that plugin or a compatible replacement.

Use an [engine hook](engine.md#engine-hooks) when async work must block, replace, or approve an engine action.

## Capabilities

A capability shares a service between plugins. The provider lists it in `provides`, and each user lists it in `uses`:

```js
// counter/index.js, with "provides": ["counter"] in its plugin.json
export default (ctx) => { ctx.provide("counter", { count: () => 1 }); };
// reader/index.js, with "uses": ["counter"]; it applies after counter, wherever config.json lists it
export default (ctx) => { ctx.get("counter")?.count(); };
```

- `ctx.get(name)` answers the capability, or `null` when no plugin provides it. Check the `null`. Throw when your plugin cannot work without it.
- One plugin provides each name. A second provider fails, and the error names the first one.
- A provider with `bindTo(ctx)` builds one value for each plugin that gets it. That plugin owns what the value registers.
- `get` and `provide` throw for a name that `uses` or `provides` does not list.
- Two plugins that use each other cannot load.

Public capabilities are `tui` and `chat`. See [Types](types.md#custom-capabilities) for a custom capability.

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

To replace a bundled plugin, list its name in `disable` in `config.json`, and list a plugin folder that `provides` the same capability. The loader applies that plugin before the bundled users of the capability. [`examples/roomy-chat.js`](examples/roomy-chat.js) replaces `chat`.

A replacement recreates each feature that it wants to preserve:

- A `chat` replacement provides `chat`. Extend `ChatSurface` to keep `render` and `refresh`, and override `create(session)`. Recreate `chat:new`, image paste, expand-all, and vision warnings when needed.
- A `transcript` replacement registers a default look with `chat.render`. See [Transcript](ui.md#transcript).
- A `sessions` replacement recreates focus tracking, session/model commands, status, and higher-level events that consumers need.
- A `command-ui` replacement recreates slash completion and the palette.
- A `shell` replacement creates and closes panes. It also supplies window commands and keys. After `/reload`, only the default `shell` brings back the panes.
- Any other replacement recreates the commands or UI listed in its table row.

Do not import bundled implementations from `yuke:internal/*`.

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

Change the focused draft from a command or input handler:

```js
import { ChatView } from "yuke:chat";

const tui = ctx.get("tui");
const view = tui?.root.active;
if (view instanceof ChatView && view.composer) {
  view.composer.input.insert("Please ");
}
```

Use a static import for `ChatView`. An `await import(...)` needs an async function. Do not use `@ts-ignore` to hide a syntax error. `currentPane()` can still name the last chat when another view has focus, so it is not a focused-draft check. `insert` preserves the other text and image spans. To save and restore attachments, use `Composer.snapshot` and `restore`, not a text-only copy. `restore` inserts saved text above newer text; it is not a draft replacement.

Observe the current pane:

```js
import { currentPane } from "yuke:session";

if (ctx.get("tui")) {
  ctx.on("pane.focused", () => {
    const pane = currentPane();
    const id = pane?.session.sessionId ?? "new draft";
    ctx.interaction.notify("focused " + id);
  });
}
```

These accessors need the bundled `sessions` plugin or a compatible replacement. They return `null` in headless modes. See [`examples/chat-api.js`](examples/chat-api.js).

`Session.startChat(null, composer)` creates an empty saved chat without a model turn. It returns a promise for the session ID. It preserves the draft and attachment spans. It rejects if creation is already in flight, the workspace is unavailable, or creation fails. Navigation during creation does not move the pane back; the promise still returns the new ID. Use `session.record_command` to save a completed direct command there. See [Completed user commands](engine.md#completed-user-commands).

## Browse and open sessions

`client.sessionList` returns one page. Use `population: { type: "top_level" }` to list root and fork sessions, not child sessions. Follow `next_cursor` until it is absent. Keep the same population and filters on each request. Copy the scalar values needed by the picker instead of keeping whole feed items.

[`examples/session-picker.js`](examples/session-picker.js) lists sessions across workspaces and opens a plugin-owned picker. Each awaited page checks `ctx.alive` before it changes UI state. `sessionList` has no cancellation parameter. Unload cannot abort an in-flight page request, so ignore its late result and stop requesting pages.

On acceptance, read `currentPane()` again and call `showSession(pane, id)`. This helper keeps the old pane and shows an error notification when opening fails. It also manages the pane's session pin. A low-level `client.sessionOpen(id)` that succeeds needs one matching `client.sessionClose(id)`; do not add another open around `showSession`.

Activity is not ownership. An idle session can belong to another process. The public API has no owner-identity or ownership preflight query. Handle an open refusal through the helper. Do not inspect lock files, change SQLite, or force another process to release its session. The picker closes before acceptance, so `currentPane()` selects the most recently focused session pane, not the picker window.

## Workspace transitions

`workspace` from `"yuke"` provides the host workspace boundary. `workspace.path` reads the current default for relative filesystem and execution helpers. `workspace.requestChange(path, sessionId)` queues a transition for the TUI driver. It returns no value. It throws for invalid arguments or a transition already queued.

A session ID forks its committed history into the destination. Null names an empty draft and creates no session. The native driver validates the directory, work state, and bundled shell before it changes the workspace. Refusal leaves the source unchanged and posts a workspace notification. Success reloads the realm and destination context. This operation needs the TUI driver; do not call it from headless tools or hooks.

A command plugin must also protect the current pane and unsent draft. `plugins/workspace` uses `currentPane()` from `"yuke:session"` and the public TUI root to enforce one pane, completed restoration, and no unrelated draft or attachments. The commands belong to that profile plugin, not to `sessions`.
