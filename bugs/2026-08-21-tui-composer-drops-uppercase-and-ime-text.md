# 2026-08-21 — TUI composer drops uppercase letters, shifted symbols, and IME-composed text

## Symptom

Focus the right pane (chat, with the `Composer` focused), type
`Shift+a Shift+b Shift+c`. The composer shows `abc`, not `ABC`. Type
`Shift+1 Shift+2` (US layout: `!@`); the composer shows `12`. Type any
Japanese character through an IME commit on a Kitty-capable terminal:
nothing appears.

Plain (unshifted) romaji flows through, which gives the impression that
"Japanese works" when in fact only the lowercase transliteration of
whatever was typed gets through.

Affected surface: `Composer` in `src/tui/js/ui.js`. The `:cmdline`
(`CommandLine` in `defaults.js`) has the same bug because it was
modelled on the same predicate.

## Cause

The composer reads `ev.char` to extend the buffer, and treats it as the
authoritative typed character:

```js
// src/tui/js/ui.js — Composer.onKey
if (ev.code === "char" && ev.char && ((ev.mods | 0) & ~MOD_SHIFT) === 0) {
  this.text += ev.char;
  return true;
}
```

But `ev.char` is **case-folded by design** in the term layer, not the
typed character. From `src/term/events.odin`:

```
// The key itself, case-folded so the same physical key reports the same value on
// every terminal. 0 for a named key and for a text-only event.
char:        rune,
```

and

```odin
emit_char :: proc(cp: rune) -> Key {
    // ...
    return Key {
        code    = .Char,
        char    = ascii_lower(cp),                          // always lowercase
        shifted = cp if cp != ascii_lower(cp) else 0,       // original here
        // ...
    }
    key_text_append(&key, cp)                              // and here
}
```

So a `Shift+a` keystroke is delivered to JS as:

```js
{ type: "key", code: "char", char: "a", shifted: "A", text: "A", mods: 1, ... }
```

The host faithfully marshals `char`, `shifted`, and `text`
(`src/tui/host.odin:host_event_object`, the `case term.Key` arm), and
`types.d.ts` declares all three on `KeyEvent`. The composer just
ignores two of them.

Two distinct drops happen in one filter:

1. **`code === "char"` only**: the predicate rejects Kitty IME commits,
   which arrive as `code === "text"` with `text` populated and `char`
   empty (`emit_char` is bypassed entirely on the Kitty text path; see
   `src/term/events.odin:663`). Any CJK / hangul / combining mark /
   emoji sent as a text event is lost.
2. **`+= ev.char` only**: the predicate accepts the keystroke but
   appends the case-folded form. The shifted form lives in `ev.shifted`
   (and is also appended to `ev.text`); both go unread.

The lowercase filter
`((ev.mods | 0) & ~MOD_SHIFT) === 0` is correct in principle — it lets
Shift through and rejects Ctrl/Alt/Super as non-text — but it
contradicts the comment immediately above it (`A printable char
(any modifier past Shift means a shortcut, not text) extends the
message`), because the "char" being appended is not what was typed
when Shift was the only modifier held.

Cross-check: `strokeOf` (`src/tui/js/core.js`) lowercases the token
for char keys on purpose and drops Shift so `g` and `G` map to the
same stroke (vim-style `gg`/`G` reuse the bound key, distinguished by
`shiftedChar`). That is the correct behavior for the keymap, where the
intent is "the same physical key". It is **not** correct for text
input, where the intent is "what the user typed".

## Repro

```
./build/yuke                                # or `./build.py yuke`
```

1. `Ctrl+w l` to focus the chat pane (composer is focused).
2. Type `Hello`. The composer shows `hello`.
3. Type `!@#`. The composer shows `13` (the unshifted digits of
   `Shift+1`/`Shift+2`/`Shift+3`); `#` from `Shift+3` is also dropped
   for the same reason.
4. With an IME (e.g. mozc/anthy on Linux, the macOS Japanese IME in
   terminal.app, the built-in IME on Windows Terminal) and a
   Kitty-capable terminal, type `konnichiwa`, commit. Nothing appears.
5. The `:` command line (`:connect`, `:q`) reproduces the same drops
   on the same predicate.

## Fix (proposed, not yet applied)

Make the composer append what the terminal said was produced, not the
case-folded identifier. The authoritative produced text is already on
the event (`ev.text`), populated by `key_text_append` for both `Char`
and `Text` keys. The minimal correct rule:

```js
// Replace the char-only predicate.
if (ev.type === "key" && ev.event !== "release" && ev.text) {
  this.text += ev.text;
  return true;
}
```

Notes on this form:

- It also handles `code === "text"` (IME commits) for free, because
  `ev.text` is set there too (`src/term/events.odin:663`, the Kitty
  text branch).
- Dropping the `ev.code === "char"` predicate removes the conflict
  with the `MOD_SHIFT` carve-out — `ev.text` is already empty for
  Alt/Ctrl-modified keys (`is_text_rune` rejects control codes and
  the ground path won't append one), so the modifier filter is
  implicit.
- `Key.shifted` and `Key.char` stay useful for `term.keyMatches`
  (`src/tui/js.js:host_term_key_matches`), which already reasons about
  case. No change needed there.

Apply the same change to `CommandLine.onKey` in `src/tui/js/defaults.js`,
which copies the predicate. (A small `Keyboard.insertText(ev)` helper
in `yuke:core` would make the rule DRY and give a single point to
reason about — worth considering as the kernel grows.)

## Notes

- Scope is "any text input the user types that is not exactly the
  ASCII lowercase form of the key". That includes uppercase letters,
  shifted symbols on US (`!@#$%^&*()_+{}|:"<>?~`), AltGr dead keys on
  European layouts, and the entire CJK input path.
- The browser-equivalent rule would be `event.key` over
  `event.code`/`event.charCode`; this code is doing the
  `event.charCode` analog. The term layer cannot send `event.key`
  directly because it doesn't know the layout, but it can — and does
  — send the produced UTF-8 in `text`.
- The `keyMatches` helper is unaffected; it still wants
  `Key.char`/`Key.shifted` for `cp`-based matching (`src/term/events.odin:180`).
- The paste path (`term.Paste`, dispatched as `{type:"paste"}` in JS)
  is unrelated and correct; a bracketed paste routes through
  `term.Paste` and bypasses `Composer.onKey` entirely. The bug only
  affects character-by-character input.
- Kitty keyboard protocol is enabled when the term drive negotiates it
  (`src/term/session_posix.odin`); the bug is not specific to Kitty —
  legacy terminals hit it the same way because `emit_char` is shared.