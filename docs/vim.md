# Vim plugins

`composerVim` and `transcriptVim` are optional plugins from `yuke:plugins`. They are independent. Enable either in `index.js`:

```js
import { plugins } from "yuke";
import { composerVim, transcriptVim } from "yuke:plugins";

plugins.use(composerVim);
plugins.use(transcriptVim);
```

They need the `tui` capability. They do nothing in `yuke -p` and `yuke --rpc`.

## Composer Vim

`composerVim` provides insert and normal modes. The focused composer enters normal mode when the plugin starts. A new composer starts in insert mode until `Esc` enters normal mode.

| Key in normal mode | Action |
|---|---|
| `h` `l`, left/right | Move by one grapheme. |
| `j` `k`, down/up | Move by one drawn row. |
| `0` `^` `$` | Move to line start, first nonblank, or line end. |
| `w` `b` `e` | Move by words. |
| `g g`, `G` | Move to the start or end of the draft. |
| `i` `a` `I` `A` | Enter insert mode at the caret, after it, at first nonblank, or at line end. |
| `o` `O` | Open a line below or above and enter insert mode. |
| `x` | Delete the grapheme under the caret. |
| `s` | Delete one grapheme and enter insert mode. |
| `D` `C` | Delete to line end; `C` then enters insert mode. |
| `d d` `c c` | Delete or change the line. These operator chords do not time out. |
| `p` `P` | Put the shared Vim register after or before the caret. |
| `Enter` | Submit the composer. |

`Esc` enters normal mode. An insert command returns to insert mode. The status bar shows `NORMAL` or `INSERT`, and normal mode changes the composer prompt.

The plugin publishes:

- context flag `composer_vim`, with value `normal` or `insert`;
- capability `composer-vim`, with `mode(composer)` and `setMode(composer, mode)`;
- event `composer-vim:mode(composer, mode)` after each change.

Example:

```js
ctx.inject(["composer-vim"], (c) => {
  c.on("composer-vim:mode", (_composer, mode) => {
    c.interaction.notify("composer mode: " + mode);
  });
});
```

## Transcript Vim

`transcriptVim` makes `Tab` switch keyboard focus between the composer and transcript. A click in transcript text also focuses it. Leaving the transcript ends visual mode and clears its selection.

| Key in transcript focus | Action |
|---|---|
| `h` `l`, left/right | Move by one grapheme in a rendered row. |
| `j` `k`, down/up | Move by one rendered row. |
| `0`/`Home`, `$`/`End` | Move to row start or end. |
| `w` `b` `e` | Move by words. |
| `{` `}` | Move to the previous or next Markdown block. |
| `K` `J` | Move to the previous or next message-part stop. |
| `g g`, `G` | Move to the first or last message. |
| `Enter` | Activate the part under the cursor. This can fold it or open its detail view. |
| `v` | Start or end visual selection. |
| `Esc` | End visual selection. |
| `o` | Swap the visual selection ends. |
| `y` | Copy the visual selection. |
| `Y` | Copy whole rendered lines. |
| `y y` | Copy the current rendered row. This operator chord does not time out. |
| `g y` | Copy the underlying message source for the current row or selection. |

The normal `transcript` context atom is active while this region has focus. Visual mode adds the flag `transcript_visual == on`. Transcript Vim has no public mode event or capability. Composer and transcript Vim share one yank register, so transcript yanks can be put with composer `p` or `P`.

## Interaction with the normal keymap

The plugins route plain keys to the keymap only in composer normal mode or transcript focus. Their context-specific bindings then take priority. Other global bindings, such as control-key commands, still work. In composer insert mode, the composer handles typed text before the normal keymap. Without transcript Vim, the bundled navigation keys scroll the transcript instead of showing a text cursor.

## Disable or replace

These plugins are not bundled. To disable one, remove its `plugins.use(...)` call and restart yuke. Code can also call `plugins.dispose("composer-vim")` or `plugins.dispose("transcript-vim")`.

To replace one, dispose it and install a plugin with your own name. Recreate any mode event, capability, context flag, focus command, or key behavior that other profile code uses. Use the public `Composer`, `TextInput`, `Transcript`, keymap, and event APIs. Do not import `yuke:internal/*`.

See [UI key routing](ui.md#key-order), [chat APIs](plugins.md#chat-and-editing-apis), and the exact `ComposerVim` declaration in `yuke.d.ts`.
