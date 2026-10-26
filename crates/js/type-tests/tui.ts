// Type checks of `yuke:tui`. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.

import type { TermEvent } from "yuke:internal/term";
import type { Command, KeyEvent, MouseEvent, PasteEvent, Style, StylePatch } from "yuke:tui";

/** `true` only when `A` and `B` are the same type. */
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;

/** A call that compiles only for `true`. */
declare function assert<T extends true>(): void;

// The public events are the events of the frame loop, so a view gets what the host sends.
assert<Equal<KeyEvent, Extract<TermEvent, { type: "key" }>>>();
assert<Equal<MouseEvent, Extract<TermEvent, { type: "mouse" }>>>();
assert<Equal<PasteEvent, Extract<TermEvent, { type: "paste" }>>>();

// A patch takes `null` to delete a field; a style does not.
const patch: StylePatch = { fg: null, bold: true, link: "title" };
// @ts-expect-error A style has no `null` field.
const style: Style = { fg: null };
// @ts-expect-error A color names the base palette or is an index, `#rrggbb`, or `reset`.
const color: Style = { fg: "red" };

// A command needs a name and a run function; `title` and `enabled` are optional.
const command: Command = { name: "notes:open", run: async () => {} };
void [patch, style, color, command];
