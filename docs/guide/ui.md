---
description: Add commands, keys, status items, and styles with the public terminal API.
---

# Terminal UI

Use `ctx.get("tui")` in the `apply` export of a plugin. It returns a `Tui` from `yuke:tui`, or `undefined` outside the terminal interface, so check it before terminal work. It needs no `uses` entry. Imports from `yuke:tui` start no terminal work in any mode.

This page covers commands, keys, status items, and styles. For dialogs, views, panes, and the `chat` service, read `types/tui.d.ts` and `types/chat.d.ts`. See [Find the API](plugins.md#find-the-api).

## Commands

Call `tui.commands.add(command)` with these fields:

| Field | Meaning |
|---|---|
| `name` | The command name. A bare name gets the plugin prefix. |
| `description` | Optional. One line for command lists. |
| `slash` | Optional. The word that a user types in the composer, such as `hi` for `/hi`. Without it, the command has no slash form. The first command with a word keeps it. |
| `argumentHint` | Optional. A hint for the text after the slash word, such as `<mode>`. With it, `/word some text` runs the command with `"some text"` as `args`. |
| `run(args)` | The action. It can return a promise, or `false` to show that it did nothing. |
| `enabled()` | Optional. A disabled command passes its key on. |

A plugin can register only its own command names. For example, plugin `hello` can register `hi` or `hello:hi`, not `chat:send`. A duplicate name throws.

`tui.commands.run(name, args?)` returns `false` when the command is absent or disabled, or when its `run` returns `false`. Otherwise, it returns `true`. A failed `run` sends a notice. The keymap does not wait for an async action, so use `enabled` to stop a second action.

See [`hello.js`](examples/hello.js) for a command and a key binding.

## Keys

Call `tui.keys.add(spec, command, options?)`. It returns a remover. A binding names a command, not a callback. A bare command name gets the plugin prefix.

- Join modifiers with `+`: `ctrl+g`, `alt+x`.
- Separate strokes with spaces: `ctrl+k x`.
- Write named keys in lowercase: `esc`, `enter`, `up`, `pageup`, `space`.
- A character keeps its case: `G` differs from `g`.

`options.in` names one context atom, such as `composer`, `transcript`, or `chat`. The default is `root`. The deepest active atom wins. Between equal matches, the newest binding wins.

## Status items

Call `tui.status.set(id, entry)` to add or replace an item. It returns a remover. An entry has `text`, `side` (`"left"` or `"right"`), and `order`, and can have `priority` and `style`. A lower `order` comes first on that side. A bare id gets the plugin prefix. Update the item when its text changes. The bundled `bar` plugin draws the items.

## Styles and themes

`tui.styles.add(groups)` changes style groups and returns a remover. A later call wins per field. A `null` field removes that field. A style can use palette names such as `accent` and `danger`.

Register a theme with `tui.styles.addTheme(name, theme)`. Activate it with `tui.styles.setTheme(name)`. The last call wins, and the remover that it returns brings back the theme before it. `tui.styles.theme` reads the active name. The active theme wins per field over `styles.add`. `tui.background` reads `"dark"` or `"light"`.

Use `ctx.addListener("theme.changed", listener)` for later changes. The listener gets `{ name, background }`. The event does not replay the initial state, so read it directly.

See [Themes](themes.md) for complete theme examples.

## Cleanup

The plugin owns its TUI registrations. When the plugin stops, yuke removes them. Each remover that a registration returns removes it early. See [Plugins](plugins.md#lifecycle) for the lifecycle.
