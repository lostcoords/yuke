---
description: Add commands, keys, status items, and styles with the public terminal API.
---

# Terminal UI

Use `ctx.get("tui")` in the named `apply` export of a plugin. It returns a `Tui` from `yuke:tui`, or `undefined` outside the terminal interface. Check that value before terminal work. The built-in `tui` service needs no `uses` entry.

Imports from `yuke:tui` start no terminal work. A plugin can import its classes and helpers in each mode.

This page covers commands, keys, status items, and styles. For dialogs, views, panes, and the `chat` service, read `types/tui.d.ts` and `types/chat.d.ts`. See [Find the API](plugins.md#find-the-api).

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

## Status items

Call `tui.status.set(id, entry)` to add or replace an item. It returns a remover. An entry has `text`, `side` (`"left"` or `"right"`), and `order`. It can also have `priority` and `style`. A lower `order` comes first on that side.

The status bar draws stored data. It does not call a plugin renderer on each frame. Update the item when its text changes. Call `tui.status.delete(id)` to remove it. A bare id gets the plugin prefix. The plugin stop removes its items.

`tui.status.list()` reads all items. `tui.status.addChangeListener(listener)` watches later changes. The bundled `bar` plugin draws them.

## Styles and themes

`tui.styles.add(groups)` changes style groups and returns a remover. A later call wins per field. A `null` field removes that field. A style can use palette names such as `accent` and `danger`.

Themes have names. Register one with `tui.styles.addTheme(name, theme)`. Registration does not activate it. Call `tui.styles.setTheme(name)` to activate it. `tui.styles.themes()` lists the names. `tui.styles.theme` reads the active name.

A theme can define `dark` and `light` looks, palette colors, 256-color alternatives, and style groups. The active theme wins per field over `styles.add` changes. `tui.background` reads `"dark"` or `"light"`. `tui.truecolor` reports 24-bit color support.

Use `ctx.addListener("theme.changed", listener)` for later theme or terminal-background changes. The listener gets `{ name, background }`. Read the initial state directly; the event does not replay it.

See [Themes](/docs/themes) for complete theme examples.

## Cleanup

TUI registrations belong to the plugin. Its stop removes them. Most registration methods also return a remover for early removal. A second removal does nothing.

Return cleanup from `apply` or `session` for other work. Pass `ctx.signal` or the session signal to async operations according to their lifetime. See [Plugins](plugins.md) for the full lifecycle.
