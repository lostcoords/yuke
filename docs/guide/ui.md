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
| `description` | Optional. One line for command lists. |
| `slash` | Optional. The word that a user types in the composer, such as `hi` for `/hi`. Without it, the command has no slash form. |
| `argumentHint` | Optional. A hint for the text after the slash word, such as `<mode>`. With it, `/word some text` runs the command with `"some text"` as `args`. |
| `run(args)` | The action. It can return a promise. `args` has type `unknown`. It can return `false` to show that it did nothing. |
| `enabled()` | Optional. A disabled command passes its key on. |

A name has letters, digits, and `:`, `-`, `_`, `.`. A plugin can register only its own command names. For example, plugin `hello` can register `hi` or `hello:hi`. It cannot register `chat:send`. A duplicate name throws.

`tui.commands.run(name, args?)` returns `false` when a command is absent or disabled, or when its `run` returns `false`. Otherwise, it returns `true`. A failed `run` returns `true` and sends a notice. The keymap does not wait for an async action. Handle any state that must stop a second action with `enabled`. `tui.commands.list()` returns each command with its `enabled` state.

The bundled chat lists the enabled commands that have a `slash` word when the composer contains one slash word. The word has no plugin prefix. The first command with a word keeps it. A later command with the same word shows its full name.

See [`hello.js`](examples/hello.js) for a command and a key binding.

## Keys

Call `tui.keys.add(spec, command, options?)`. It returns a remover. A binding names a command, not an input callback. A bare command name gets the plugin prefix.

- Join modifiers with `+`: `ctrl+g`, `alt+x`, `shift+tab`.
- Separate strokes with spaces: `ctrl+k x`.
- Use lowercase names for named keys: `esc`, `enter`, `up`, `pageup`, `space`.
- A character is case-sensitive: `G` differs from `g`.

`options.in` names one context atom, such as `composer`, `transcript`, or `chat`. It is not a Boolean expression. The default atom is `root`. The deepest active atom wins. Between equal matches, the newest binding wins. A pending sequence waits one second for its next stroke.

`tui.keys.pending()` returns the pending strokes as text, such as `ctrl+k`, or an empty string. `tui.keys.list(command)` returns the key specs of a command, the newest first.

For custom input behavior, use the `onKey` handler of a view, a text widget extension, or `tui.addInputHandler(handler)`. A text extension can handle a key before the keymap or before the default behavior of the widget. An input handler sees each key, mouse, and paste event first.

## Status items

Call `tui.status.set(id, entry)` to add or replace an item. It returns a remover. An entry has `text`, `side` (`"left"` or `"right"`), and `order`. It can also have `priority` and `style`. A lower `order` comes first on that side.

The status bar draws stored data. It does not call a plugin renderer on each frame. Update the item when its text changes. Call `tui.status.delete(id)` to remove it. A bare id gets the plugin prefix. The plugin stop removes its items.

`tui.status.list()` reads all items. `tui.status.addChangeListener(listener)` watches later changes. The bundled `bar` plugin draws them.

## Time and redraw

Use these methods for a clock or a delayed change:

| Method | Use |
|---|---|
| `tui.now()` | Read the clock in milliseconds. Subtract two readings for a duration. |
| `tui.addTimer(delay, callback)` | Call once after a delay. The returned remover cancels it. |
| `tui.requestFrame(delay?)` | Request a frame after a state change outside input handling. |

A timer callback causes a frame. The plugin stop cancels its pending callbacks. For repeated work, schedule the next callback only while that work remains active. Compute elapsed time from the clock, not from the number of callbacks.

[`stopwatch.js`](examples/stopwatch.js) starts, stops, and resets a status clock. It schedules no callbacks while stopped.

## Styles and themes

`tui.styles.add(groups)` changes style groups and returns a remover. A later call wins per field. A `null` field removes that field. A style can use palette names such as `accent` and `danger`.

Themes have names. Register one with `tui.styles.addTheme(name, theme)`. Registration does not activate it. Call `tui.styles.setTheme(name)` to activate it. `tui.styles.themes()` lists the names. `tui.styles.theme` reads the active name.

A theme can define `dark` and `light` looks, palette colors, 256-color alternatives, and style groups. The active theme wins per field over `styles.add` changes. `tui.background` reads `"dark"` or `"light"`. `tui.truecolor` reports 24-bit color support.

Use `ctx.addListener("theme.changed", listener)` for later theme or terminal-background changes. The listener gets `{ name, background }`. Read the initial state directly; the event does not replay it.

See [Themes](/docs/themes) for complete theme examples.

## Selectors and dialogs

`tui.select({ items, label, title?, detail?, signal? })` opens a searchable selector. `label` gives the text of an item. Equal items are one choice. It resolves to the chosen item, or `undefined` on cancellation. The plugin stop also ends the wait.

`tui.input({ title?, placeholder?, text?, mask?, onSubmit?, signal? })` asks for one line of text. It resolves to the text, or `undefined` on cancellation. `tui.confirm({ text, title?, confirmLabel?, signal? })` resolves to `true` for Enter and `false` for Esc.

[`picker.js`](examples/picker.js) lets the user choose a review focus. It stores the result in a status item. [`session-picker.js`](examples/session-picker.js) lists one page of saved sessions and opens the selected session through the `chat` service.

For a custom selector, import `Picker` from `yuke:tui`. A picker is a view. It opens no overlay itself. Place it with `tui.dialog({ body, ... })` or `tui.overlay(factory, options?)`. Its `onChoose` and `onCancel` options must close the mount when appropriate. Give it an `id` function that returns a stable id for each item.

`tui.dialog` and `tui.overlay` return a `Mount`. Call `mount.close()` to close it. `mount.signal` aborts when it closes. Use that signal for work that belongs to the open dialog.

## Views, panes, and mounts

A `View` draws through a `Canvas`. It can also define layout, input handlers (`onKey`, `onMouse`, `onPaste`), focus behavior, and a snapshot. Coordinates count terminal cells from zero. Text offsets count UTF-16 units.

- `tui.panes.split(factory, { direction })` creates a pane. `direction` is `"row"` or `"column"`.
- `tui.panes.active` reads the active pane beneath a modal.
- `tui.focused` reads the deepest focused view.
- `tui.focus(view)` requests focus for a placed view. It returns `false` when the view cannot take focus.
- `tui.wrapRoot(factory)` adds a root view around the current root. The factory gets the mount and the inner root. Closing its mount removes only this root.
- `tui.panes.setDefault(factory)` sets the view of each pane that the core opens. The last call wins.
- `tui.views.add(type, restore)` registers a saved view type for reload.

A factory receives a `Mount`. Its signal ends work when that view closes. Register a view type and supply `view.snapshot()` when a custom pane needs reload restoration.

Import `stack` from `yuke:tui` for a row or column layout. Each child has a fixed cell size, `"fill"`, or a size callback. [`sidebar.js`](examples/sidebar.js) places a small help column beside the inner root. It hides that column in a narrow terminal. It does not replace the chat pane implementation.

## Text widgets

`TextEditor` edits a draft. `TextView` displays a document of items and sections. Each item and each section has an `id`. `Markdown` projects Markdown text into styled rows. All three come from `yuke:tui`.

Use `tui.widgets.addWatcher(attach)` to extend current and later text widgets. Filter by widget class and role. The callback gets a placed widget with `widget`, `pane`, `group`, and `signal`. `widget.extend(signal)` adds owned appearance, contexts, decorations, and input handlers without replacing another plugin's callbacks.

[`roomy-chat.js`](examples/roomy-chat.js) changes only the prompt of composer editors. Its extension leaves when the widget unmounts or the watch ends.

## Chat services and blocks

The bundled `chat` plugin provides the `chat` service. Declare `"uses": ["chat"]` in the manifest entry before calling `ctx.get("chat")`. Check `tui` first when the feature needs a terminal.

| Chat service method | Use |
|---|---|
| `show(id)` | Open a session in a chat pane. |
| `session(view)` | Read the session of a chat pane view. |
| `addChangeListener(listener)` | Watch changes to the session of chat panes. |
| `addPaneWatcher(watch)` | Call a function for each chat pane, now and later. |
| `addCompletionProvider(provider)` | Add completions for the composer. |
| `addComposerView(place, create)` | Add a view above or below composers. |
| `addReadOnly(source)` | Show selected sessions without a composer. |
| `setComposerFrame(frame)` | Replace the frame around the input. |
| `setPresentation(factory)` | Replace transcript presentation. |
| `setEmptyView(create)` | Replace the view of an empty transcript. |

A composer view says its height with `heightFor(width)`. `composerRows(source)` from `yuke:chat` makes one from plain text rows. Its source runs at each layout and draw. Keep it cheap and synchronous. Call `tui.requestFrame()` after its data changes. [`chat-api.js`](examples/chat-api.js) adds a session label below each composer.

A read-only source gets a session id. It returns `{ text, back }` for a selected session, or `undefined` for an editable session. The first source that answers wins. The pane shows that text instead of the composer. This rule changes the terminal pane only; an RPC client can still send input.

For a new chat frontend, use the public blocks from `yuke:chat`: `ChatSession`, `ChatComposer`, `ChatQuestions`, `ChatCompletions`, `ChatWorking`, and `ChatDocument`. `ChatSession` owns the shown session handle, transcript, and history pages. It does not create a terminal pane. Combine only the blocks that the frontend needs.

## Transcript presentation

`Transcript` from `yuke:transcript` folds session events into typed entries. `ChatDocument` from `yuke:chat` projects those entries into a `TextDocument`. The default document supports Markdown, tool calls, reasoning, errors, and folds.

`chat.setPresentation(factory)` installs a `ChatPresentation` for each chat pane. The factory gets a document `id`, saved `folds`, an abort `signal`, and a `requestUpdate()` callback. The last factory wins. Its remover brings back the factory before it.

A presentation must implement `folds`, `toggle`, `toggleTools`, and `project`. Keep item ids across updates. Keep each unchanged item object so text views can reuse its rows. Call `options.requestUpdate()` after a presentation state change that needs a new projection.

[`tree-transcript.js`](examples/tree-transcript.js) wraps `ChatDocument`. It adds plain tree marks to labels and keeps the default fold behavior. It does not group tool calls or add a details window.

## Cleanup

TUI registrations and mounts belong to the plugin. Its stop removes them. Most registration methods also return a remover for early removal. A second removal does nothing.

Return cleanup from `apply` or `session` for other work. Pass `ctx.signal`, the session signal, or a mount signal to async operations according to their lifetime. See [Plugins](plugins.md) for the full lifecycle.
