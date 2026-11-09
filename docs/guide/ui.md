---
description: Add commands, keys, views, status items, dialogs, and chat presentation with the public terminal API.
---

# Terminal UI

Use `ctx.get("tui")` in the named `apply` export of a plugin. It returns a `Tui` from `yuke:tui`, or `undefined` outside the terminal interface. Check that value before terminal work. The built-in `tui` service needs no `uses` entry.

Imports from `yuke:tui` start no terminal work. A plugin can import its classes and helpers in each mode.

## Commands

Call `tui.commands.add(command)` with these fields:

| Field | Meaning |
|---|---|
| `name` | The command name. A bare name gets the plugin prefix. |
| `description` | One line for command lists. |
| `run(args)` | The action. It can return a promise. `args` has type `unknown`. |
| `enabled()` | An optional test. A disabled command passes its key on. |

A plugin can register only its own command names. For example, plugin `hello` can register `hi` or `hello:hi`. It cannot register `chat:send`. A duplicate name throws.

`tui.commands.run(name, args?)` returns `false` when a command is absent or disabled. Otherwise, it returns `true`. The keymap does not wait for an async action. Handle any state that must stop a second action with `enabled`.

The bundled chat lists enabled commands when the composer contains one slash word. A plugin command keeps its prefix, such as `/hello:hi`. It needs no `slash` field. This list does not parse command arguments.

See [`hello.js`](examples/hello.js) for a command and a key binding.

## Keys

Call `tui.keys.bind(spec, command, options?)`. A binding names a command, not an input callback. A bare command name gets the plugin prefix.

- Join modifiers with `+`: `ctrl+g`, `alt+x`, `shift+tab`.
- Separate strokes with spaces: `ctrl+k x`.
- Use lowercase names for named keys: `esc`, `enter`, `up`, `page_up`.
- A character is case-sensitive: `G` differs from `g`.

`options.in` names one context atom, such as `composer`, `transcript`, or `chat`. It is not a Boolean expression. The default atom is `root`. The deepest active atom wins. Between equal matches, the newest binding wins. A pending sequence waits one second for its next stroke.

`tui.keys.pending()` returns the pending strokes. `tui.keys.keysOf(name)` returns the bindings of a command.

For custom input behavior, use a view's `key` handler or a text widget extension. A text extension can handle a key before the keymap or before the widget's default behavior.

## Status items

Call `tui.status.set(key, entry)` to add or replace an item. An entry has `text`, `side` (`"left"` or `"right"`), and `order`. It can also have `priority` and `style`. A lower `order` comes first on that side.

The status bar draws stored data. It does not call a plugin renderer on each frame. Update the item when its text changes. Call `tui.status.delete(key)` to remove it. A bare key gets the plugin prefix. The plugin stop removes its items.

`tui.status.list()` reads all items. `tui.status.onChange(listener)` watches later changes. The bundled `bar` plugin draws them.

## Time and redraw

Use these methods for a clock or a delayed change:

| Method | Use |
|---|---|
| `tui.now()` | Read the clock in milliseconds. Subtract two readings for a duration. |
| `tui.after(delay, callback)` | Call once after a delay. The returned remover cancels it. |
| `tui.requestFrame(delay?)` | Request a frame after a state change outside input handling. |

An `after` callback causes a frame. The plugin stop cancels its pending callbacks. For repeated work, schedule the next callback only while that work remains active. Compute elapsed time from the clock, not from the number of callbacks.

[`stopwatch.js`](examples/stopwatch.js) starts, stops, and resets a status clock. It schedules no callbacks while stopped.

## Styles and themes

`tui.styles.set(groups)` changes style groups. A later call wins per field. A `null` field removes that field. A style can use palette names such as `accent` and `danger`.

Themes have names. Register one with `tui.styles.addTheme(name, theme)`. Registration does not activate it. Call `tui.styles.setTheme(name)` to activate it. `tui.styles.themes()` lists the names. `tui.styles.theme` reads the active name.

A theme can define `dark` and `light` looks, palette colors, 256-color alternatives, and style groups. The active theme wins over `styles.set` changes. `tui.background` reads `"dark"` or `"light"`. `tui.truecolor` reports 24-bit color support.

Use `ctx.on("theme.changed", listener)` for later theme or terminal-background changes. The listener gets `{ name, background }`. Read the initial state directly; the event does not replay it.

See [Themes](/docs/themes) for complete theme examples.

## Selectors and dialogs

`tui.select({ items, label, title?, signal? })` opens a searchable selector. Each item is an object. It resolves to the chosen item, or `undefined` on cancellation. The plugin stop also ends the wait.

[`picker.js`](examples/picker.js) lets the user choose a review focus. It stores the result in a status item. [`session-picker.js`](examples/session-picker.js) lists one page of saved sessions and opens the selected session through the `chat` service.

For a custom selector, import `Picker` from `yuke:tui`. A picker is a view. It opens no overlay itself. Place it with `tui.dialog({ body, ... })` or `tui.overlay(factory, options?)`. Its `choose` and `cancel` callbacks must close the mount when appropriate.

`tui.dialog` and `tui.overlay` return a `Mount`. Call `mount.close()` to close it. `mount.signal` aborts when it closes. Use that signal for work that belongs to the open dialog.

## Views, panes, and mounts

A `View` draws through a `Canvas`. It can also define layout, input handlers, focus behavior, and a snapshot. Coordinates count terminal cells from zero. Text offsets count UTF-16 units.

- `tui.panes.split(factory, { direction })` creates a pane. `direction` is `"row"` or `"column"`.
- `tui.panes.active` reads the active pane beneath a modal.
- `tui.focused` reads the deepest focused view.
- `tui.focus(view)` requests focus for a placed view.
- `tui.wrapRoot(factory)` adds a root view around the current root. The factory gets the mount and the inner root. Closing its mount removes only this root.
- `tui.views.register(type, restore)` registers a saved view type for reload.

A factory receives a `Mount`. Its signal ends work when that view closes. Register a view type and supply `view.snapshot()` when a custom pane needs reload restoration.

Import `stack` from `yuke:tui` for a row or column layout. Each child has a fixed cell size, `"fill"`, or a size callback. [`sidebar.js`](examples/sidebar.js) places a small help column beside the inner root. It hides that column in a narrow terminal. It does not replace the chat pane implementation.

## Text widgets

`TextEditor` edits a draft. `TextView` displays a document of keyed items and sections. `Markdown` projects Markdown text into styled rows. All three come from `yuke:tui`.

Use `tui.widgets.watch(attach)` to extend current and later text widgets. Filter by widget class and role. The callback gets the widget, its pane, and a mount signal. `widget.extend(signal)` adds owned appearance, contexts, decorations, and input handlers without replacing another plugin's callbacks.

[`roomy-chat.js`](examples/roomy-chat.js) changes only the prompt of composer editors. Its extension leaves when the widget unmounts or the watch ends.

## Chat services and blocks

The bundled `chat` plugin provides the `chat` service. Declare `"uses": ["chat"]` in the manifest entry before calling `ctx.get("chat")`. Check `tui` first when the feature needs a terminal.

| Chat service method | Use |
|---|---|
| `show(id)` | Open a session in a chat pane. |
| `session(view)` | Read the session of a chat pane view. |
| `onChange(listener)` | Watch changes to the session of chat panes. |
| `addComposerView(place, factory)` | Add a view above or below composers. |
| `setReadOnly(source)` | Show selected sessions without a composer. |
| `setPresentation(factory)` | Replace transcript presentation. |

A composer view says its height with `heightFor(width)`. `composerRows(source)` from `yuke:chat` makes one from plain text rows. Its source runs at each layout and draw. Keep it cheap and synchronous. Call `tui.requestFrame()` after its data changes. [`chat-api.js`](examples/chat-api.js) adds a session label below each composer.

A read-only source returns `{ text, back }` for a selected session, or `undefined` for an editable session. The pane shows that text instead of the composer. This rule changes the terminal pane only; an RPC client can still send input.

For a new chat frontend, use the public blocks from `yuke:chat`: `ChatSession`, `ChatComposer`, `ChatQuestions`, `ChatCommands`, `ChatWorking`, and `ChatDocument`. `ChatSession` owns the shown session handle, transcript, and history pages. It does not create a terminal pane. Combine only the blocks that the frontend needs.

## Transcript presentation

`Transcript` from `yuke:transcript` folds session events into typed entries. `ChatDocument` from `yuke:chat` projects those entries into a `TextDocument`. The default document supports Markdown, tool calls, reasoning, errors, and folds.

`chat.setPresentation(factory)` installs a `ChatPresentation` for each chat pane. The factory gets a document key, saved folds, an abort signal, and a `requestUpdate()` callback. The last factory wins. Its remover restores the default only if that factory remains current.

A presentation must implement `folds`, `toggle`, `toggleTools`, and `project`. Keep item keys across updates. Keep each unchanged item object so text views can reuse its rows. Call `options.requestUpdate()` after a presentation state change that needs a new projection.

[`tree-transcript.js`](examples/tree-transcript.js) wraps `ChatDocument`. It adds plain tree marks to labels and keeps the default fold behavior. It does not group tool calls or add a details window.

## Cleanup

TUI registrations and mounts belong to the plugin. Its stop removes them. Most registration methods also return a remover for early removal. A second removal does nothing.

Return cleanup from `apply` or `session` for other work. Pass `ctx.signal`, the session signal, or a mount signal to async operations according to their lifetime. See [Plugins](plugins.md) for the full lifecycle.
