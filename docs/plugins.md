# Plugins: lifecycle, events, capabilities, advice

A plugin is `{ name, apply(ctx) }`. Register it with `plugins.use(plugin)`. Two plugins with one name throw. `ctx` is `Context` in `yuke.d.ts`.

## Lifecycle

| Member | Use |
|---|---|
| `ctx.effect(fn)` | Run `fn` now. A function that `fn` returns runs at unload. |
| `ctx.own(release)` | Hold a resource until unload. `release` may be async. |
| `ctx.signal` | Cancels at unload. Pass it to `fetch`, `exec`, and sockets. |
| `ctx.alive` | `false` after unload starts. Check it after an `await`. |
| `ctx.use(plugin)` | Start a child plugin that unloads with this one. |

Register in the synchronous part of `apply`. yuke does not wait for an async `apply`.

## Startup order

In the TUI and in `yuke check`, yuke starts the bundled plugins, then the `prompt` plugin, then `index.js`, then the built-in tools. So `index.js` can dispose or replace a bundled plugin, the `tui` capability exists when `index.js` runs, and a tool that `index.js` defines replaces a built-in tool with the same name. `yuke -p` and `yuke --rpc` start no bundled plugin and no `tui`.

## Events

- `ctx.on(name, fn)` and `ctx.once(name, fn)` listen, and the listener goes away at unload. Use them, not `events.on`.
- `events.emit(name, ...args)` (from `yuke`) tells every listener.
- `events.bail(name, ...args)` asks the newest listener first and returns the first answer that is not `null`, `undefined`, or `false`.
- Search `interface Events` in `yuke.d.ts` for the names and arguments. Common ones: `session.changed`, `run.started`, `run.done`, `message.committed`, `composer.changed`, `key.pressed`, `pane.focused`.
- An engine fact (`run.started`, `run.done`, `message.*`, `tool.*`, and the other names from `DrainFact`) passes the whole drain, not the fact. When `ev.type === "session"`, `ev.session` is the session id and `ev.facts` lists the facts. Read more with `client` (search `declare namespace $client`).
- Name your own events `<plugin>:<name>`. A bare unknown name throws.

## Capabilities

A capability shares a service between plugins.

```js
ctx.provide("counter", { count: () => 1 });                       // plugin A
ctx.inject(["counter"], (c) => { c.counter.count(); });            // plugin B
```

- The `inject` block runs only while every named capability has a provider. It runs again when a provider changes.
- A provider with `bindTo(ctx)` gives each block its own object, and the block owns what that object registers.
- To type your own capability, see [Types](types.md).
- Built-in capabilities: `tui` (see [UI](ui.md)), `chat` (the chat pane), `composer-vim` (with the `composerVim` plugin).
- A name of a `Context` member, such as `interaction`, throws.

## Advice

Advice changes a method of a yuke object.

`ctx.advise(obj, "method", where, fn, { name?, order? })`, with `where` as one of:

| `where` | `fn` receives | `fn` returns |
|---|---|---|
| `before`, `after` | the arguments | nothing |
| `around` | `next`, then the arguments | the result; call `next(...args)` for the original |
| `filterArgs` | the argument array | new arguments, or nothing to keep them |
| `filterReturn` | the result | a new result, or `undefined` to keep it |

`this` is the object. The types check the method name and the arguments. Common targets: `ChatView.prototype` (from `yuke:chat`) and `Session.prototype` (from `yuke:session`).

## Replace a bundled plugin

`plugins.dispose("<name>")`, then `plugins.use(yourPlugin)`. Bundled names: `keys`, `toasts`, `command-ui`, `catalog`, `auth`, `jobs-ui`, `sessions`, `transcript`, `chat`, `indicator`, `queue`, `context`, `cache`, `quit-guard`, `shell`. Prefer the smallest change: advice first, then events, then a replacement.

## Change the chat

The `sessions` plugin owns the engine sessions: pins, input, activity, the session list, the default model, and the session commands. The `chat` plugin owns the chat pane and the renderer stack: the shell asks the `chat` capability for each new pane, and a look registers with `chat.render`.

Use the smallest level that does the job:

1. Advice. Change one method of `ChatView` or `Session` with `ctx.advise`.
2. Events and renderers. Answer `chat.rule`, `chat.strip`, `chat.cursor`, or `chat.press`. Change the transcript with a renderer (see [UI](ui.md#transcript)).
3. Your own pane. Replace the `chat` capability: extend `ChatSurface` from `yuke:chat` and override `create(session)`. A pane holds a `Session`, a `Transcript`, and a `Composer`. It calls `session.join(this)` one time, and the session layer calls `leave` when the pane closes. The bundled `chat` plugin also owns `chat:new` (ctrl+n), `chat:paste-image` (ctrl+v), `chat:expand-all` (ctrl+o), and the vision warning, so a replacement brings its own.
4. Your own window layout. Replace the `shell` plugin.

[`examples/roomy-chat.js`](examples/roomy-chat.js) replaces the chat pane with one that keeps a margin.
