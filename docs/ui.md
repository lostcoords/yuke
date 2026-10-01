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

A context is an expression over atoms: `chat`, `composer`, `transcript`, and `overlay`. Test your own flag with `==` or `!=`: a bare flag name never matches. Operators: `!`, `&&`, `||`, `==`, `!=`, `()`.

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
| `ctrl+o` | `chat:expand-all` |
| `ctrl+q`, `ctrl+z` | `quit`, `suspend` |
| `ctrl+k` then `h j k l w v s c` or an arrow | window focus, split, and close |
| `j` `k`, arrows, `ctrl+d` `ctrl+u`, page keys, `home` `end`, `g g`, `G` | scroll; the composer takes plain letters first |

## Status bar

`c.tui.status.add({ side?, order?, render })`. `render` returns a string. `null`, `undefined`, or `""` hides the item, and a throw hides it and reports a fault. It runs on each frame, so keep it cheap. Items on one side join with ` · `.

## Styles

`c.tui.style` holds the highlight groups and the palette. Each change repaints, and its disposer (or the plugin unload) removes it.

- `set({ Name: { fg: "danger" } })` changes fields of any group. `null` removes a field. A later `set` wins.
- `set({ MyGroup: { fg, bg, ul, bold, dim, italic, reverse, underline, link } }, { default: true })` sets the default of a group that your plugin owns. It sits below the theme and every other `set`, so it never undoes a change of the user. A second default for one name, such as `YukeStatus`, throws; Neovim keeps the first one silently.
- `setPalette({ accent: "#88c0d0" })` changes palette colors. A color can also be a literal: `"#88c0d0"`, a 256-color index such as `151`, or a name such as `"green"`.
- The default palette names `fg`, `bg`, `surfaceFg`, `strongFg`, `accent`, `accentMuted`, `surface`, `warn`, `danger`, `pendingBg`, `errorBg`, `diffAddBg`, and `diffDelBg`. It follows the terminal background and the color depth, and the theme and each `setPalette` sit above it.
- `theme({ groups, palette })` makes one theme active, above the defaults and below every other `set`. A new call replaces it, so a theme switcher calls it again at runtime. The disposer of a replaced theme does nothing.
- A `link` takes the fields of the linked group, and the group's own fields win.
- `UIComposer` styles the composer surface. `UIComposerPrompt` styles the prompt while the composer reads the keyboard, and `UIComposerPromptInactive` styles it at other times. Both link to `UIComposer`. `UIComposerPlaceholder` also links to the surface and styles the placeholder, which an empty composer shows only without focus. `UIPrompt` remains the picker and dialog prompt.

### Terminal background

`c.tui.background` is `"dark"` or `"light"`, from the terminal background color. It is set before `index.js` runs, and stays `"dark"` if the terminal does not answer.

```js
ctx.inject(["tui"], (c) => {
  const pick = () => c.tui.style.theme(c.tui.background === "light" ? light : dark); // { palette, groups }
  pick();
  c.on("background.changed", pick);
});
```

`background.changed` fires when the class changes: a late answer, a resume, or a light/dark switch in a terminal that reports it.

### Color depth

`c.tui.colors` is `"truecolor"` when yuke draws 24-bit colors, or `"256"` when it uses the 256-color palette. The `colors` setting picks it (see [defineConfig](engine.md)): `"auto"` follows `COLORTERM`, like `termguicolors` in Neovim. `colors.changed` fires when the setting changes.

yuke sends a hex color as it is, and a terminal without 24-bit color shows it wrong. So a theme with hex colors also gives 256-color indices, and picks again on each change:

```js
ctx.inject(["tui"], (c) => {
  const pick = () => c.tui.style.theme(themes[c.tui.colors][c.tui.background]); // themes.truecolor.dark, themes["256"].light, ...
  pick();
  c.on("background.changed", pick);
  c.on("colors.changed", pick);
});
```

## Dialogs and pickers

```js
import { ui } from "yuke:ui";

const { win } = ui.pick({ items: ["a", "b"] }); // search `PickOptions` for the options
c.tui.overlay(win); // nothing shows until overlay
```

- For a one-line question, use `c.interaction.confirm`, `select`, or `input`. They return a promise, which resolves to `undefined` when the user cancels.
- For a short message, use `c.interaction.notify(message, level?)`. It shows a toast.
- To change the draft, use `currentPane()?.composer?.input` (`yuke:session`): `insert(text)` types at the caret, and `setText(text)` replaces the draft. See [Chat and editing APIs](plugins.md#chat-and-editing-apis).
- `c.tui.split("row" | "col", view)` adds a pane. `c.tui.root` is the window tree.
- `layout` (`yuke:ui`) solves a row or a column of `fixed`, `fit`, and `grow` cells into rects. [`examples/sidebar.js`](examples/sidebar.js) keeps a right column in each chat pane with it.
- `List` is a scrollable list inside your own view; `Window` frames a view, and `borders` names its glyph sets.
- `attachPath(composer, text, from)` (`yuke:chat`) attaches the image file that a pasted path names.
- For modal composer and transcript keys, see [Vim plugins](vim.md).

## Transcript

The `transcript` plugin draws every chat transcript. A renderer changes it through `c.chat.render`. Renderers stack: a hook that answers `undefined` passes to the renderer below, and `tools` and `sources` merge by name. The disposer, or the plugin unload, removes the renderer.

```js
ctx.inject(["chat"], (c) => {
  c.chat.render({ tools: { web_search: (args) => ({ verb: "search", subject: String(args.query), input: "" }) } });
});
```

- `tools` sets one complete tool heading: `verb`, `subject`, and `input`. `input` holds the raw source of `subject`. A nonempty `input` with each line feed replaced by a space must equal `subject`. Normalization drops an `input` that does not match. Use an empty `input` when there is no hidden input. The default look sets headings for `read`, `write`, `edit`, `exec`, and `skill`.
- `sources` sets the label of an input from an engine source, such as a child report.
- `part(part, env)` answers `{ rows, source }` for one tool or reasoning part. The core builds text parts as markdown, indented by `indent`. `gap` blank rows separate two parts.
- `message`, `error`, `fold`, `activate`, `sameVisible`, `groupKey`, and `groupHeader` change the rest. Search `interface Render` in `yuke.d.ts`.
- A row sets `header` on the row that a click folds, and `stop` on each row where part motion lands (J and K in `transcriptVim`). A segment `src`/`srcEnd` indexes `source`, so a copy takes the source text. Answer the same `source` folded and open: a fold changes the rows alone, so the cursor and a selection keep their text across ctrl+o.
- The default renderer folds each reasoning part with text to one header row, also while it streams. The header reads like a tool heading: `thinking <title>` while the block streams with no duration yet, and `thought <title> · 12.3s` after it stops. A provider that hides its reasoning sends no text. That thought shows nothing while it streams, and after it stops it shows one `thought · 12.3s` row that does not fold. The engine sends `title`, the title of the latest summary section, only for a provider that writes one, such as OpenAI Responses. It sends `duration_ms` at the block stop.
- ctrl+o (`chat:expand-all`) opens or folds every part that folds. A click on a block toggles it, and a part that the user opens stays open. A rebuild, such as ctrl+o or a resize, keeps the text under `transcript.caret` on its screen row. `transcriptVim` sets the caret while the transcript has focus. Without a caret, the top row stays, or the pane follows the tail. The default exec renderer shows the original command below its header when the header clipped it or flattened a line feed.
- A row `bg` group is the base style of the complete row. Its background wins over ordinary text backgrounds. An overlay with an explicit background, such as `TxSelect`, wins over the row. A selection keeps every content field that it does not set. A tool block uses `TxToolPendingBg`, `TxToolSuccessBg`, or `TxToolErrorBg`, and a user message uses `TxUser`. A pending tool block has the `pendingBg` color. A failed or canceled tool block has the `errorBg` color. A completed tool block has no background. `TxUser` puts the `surface` color behind a user message. Its text starts at the same column as every other row.

[`examples/tree-transcript.js`](examples/tree-transcript.js) stacks a whole look: tool calls grouped under "N actions" in a tree, a three-row preview, and a details window.

