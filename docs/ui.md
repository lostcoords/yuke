# TUI: commands, keys, status bar, styles, dialogs

Put all TUI code in `ctx.inject(["tui"], (c) => { ... })`. The block runs only while the TUI exists, and it reverts when the plugin unloads. `c.tui` is `Surface` in `yuke.d.ts`.

## Commands

`c.tui.command.add(name, spec)`

- A bare name gets the plugin prefix: `"hello"` in plugin `example` is `example:hello`. A name with `:` stays as written.
- `spec` is `CommandSpec`: `run`, `when?` (a function), `desc?`, `slash?`, `args?`, `aboveModal?`.
- `desc` lists the command in the ctrl+p palette.
- `slash: true` adds `/<name after the last ":">`. `slash: "word"` adds `/word`. A slash command needs `desc`.
- `args: true` gives the rest of the slash line to `run`.
- A newer command with the same name hides the older one. When `when` answers false, the older one runs. When `when` answers `[true, ...args]`, `run` gets those arguments.

## Keys

`c.tui.keymap.add(bindings, context?, { pending? })`

- `bindings` maps a key to a command name, a function `(ev) => boolean | void`, or a list of them. A function that returns `false` passes the key on.
- Key syntax:
  - Modifiers join with `+`: `ctrl+g`, `alt+x`, `shift+tab`.
  - A space separates the keys of a sequence: `"g g"`, `"ctrl+k v"`.
  - Named keys are lowercase: `tab`, `esc`, `enter`, `up`, `page_up`.
  - One character is case-sensitive: `G` is not `g`.
- `pending: "chord"` (the default) waits `config.keymap.chordMs` for the next key. `"operator"` waits without a time limit.
- The binding whose context matches the deepest view wins. Between equal matches, the newest binding wins.

### Contexts

A context is an expression over atoms: `chat`, `composer`, `transcript`, `overlay`, and your own flags. Operators: `!`, `&&`, `||`, `==`, `!=`, `()`.

```js
c.tui.keymap.add({ "ctrl+t": "example:toggle" }, "chat && !overlay");
c.tui.context.add({ example_mode: () => (on ? "on" : "off") }); // then: "example_mode == on"
```

### Key order

1. A command with `aboveModal`.
2. An open dialog. A modal dialog takes every key.
3. The keymap, when a sequence is pending or `c.tui.route` sends the context to the keymap.
4. The focused view, and then the keymap if the view does not use the key.

A key that the composer types (a plain letter) reaches the keymap only through `c.tui.route.add("keymap", context)`.

### Default keys

Do not bind these unless the user asks you to replace one.

| Key | Command |
|---|---|
| `ctrl+p` | `ui:palette` (all described commands) |
| `ctrl+n` | `chat:new` |
| `ctrl+f` | `ui:sessions` |
| `ctrl+c` | `session:interrupt`; `modal:cancel` in a dialog |
| `ctrl+l` | `notify:dismiss` |
| `ctrl+v` | `chat:paste-image` |
| `ctrl+q`, `ctrl+z` | `quit`, `suspend` |
| `ctrl+k` then `h j k l w v s c` or an arrow | window focus, split, and close |
| `j` `k`, arrows, `ctrl+d` `ctrl+u`, page keys, `home` `end`, `g g` | scroll; the composer takes plain letters first |

## Status bar

`c.tui.status.add({ side?, order?, render })`. `render` returns a string. `null`, `undefined`, or `""` hides the item, and a throw hides it and reports a fault. It runs on each frame, so keep it cheap. Items on one side join with ` · `.

## Styles

`c.tui.style.add({ Name: { fg, bg, bold, dim, italic, reverse, underline, link } })` defines new groups, and the disposer removes them. It does not change a group that exists. To change a built-in group such as `YukeStatus` or `TxToolRead`, set `c.tui.style.groups.Name` and call `c.tui.style.invalidate()`. That change stays after the plugin unloads. The palette colors are `fg`, `bg`, and `danger`; a color can also be a literal such as `"#88c0d0"`.

## Dialogs and pickers

```js
import { ui } from "yuke:ui";

const { win } = ui.pick({ items: ["a", "b"] }); // search `PickOptions` for the options
c.tui.overlay(win); // nothing shows until overlay
```

- For a one-line question, use `c.interaction.confirm`, `select`, or `input`. They return a promise, which resolves to `undefined` when the user cancels.
- For a short message, use `c.interaction.notify(message, level?)`. It shows a toast.
- To change the draft, use `currentPane()?.composer?.input` (`yuke:session`): `insert(text)` types at the caret, and `setText(text)` replaces the draft.
- `c.tui.split("row" | "col", view)` adds a pane. `c.tui.root` is the window tree.

## Tool labels

A label sets the words of a tool call row in the transcript: `verb`, then `subject`.

```js
ctx.inject(["chat"], (c) => {
  c.chat.labels({ tools: { web_search: { category: "run", present: (args) => ({ verb: "search", subject: String(args.query) }) } } });
});
```

- yuke has labels for its own tools. A label for `read`, `edit`, or `exec` replaces the built-in one, and with it the short path format.
- A presenter outside the call has no inferred types: annotate it with `/** @type {import("yuke:chat").Presenter} */`.
- `category` picks the style group of the row. Search `interface Presenter` in `yuke.d.ts` for the values.
