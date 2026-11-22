// Type checks of `yuke:tui`. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.

import type { TermEvent } from "yuke:internal/term";
import type { PluginContext } from "yuke:plugins";
import type { KeyEvent, Style, StylePatch, Tui } from "yuke:tui";
import type * as Runtime from "../modules/runtime/tui.ts";

/** `true` only when `A` and `B` are the same type. */
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;

/** A call that compiles only for `true`. */
declare function assert<T extends true>(): void;

// The runtime module exports exactly the declared values, so no export is missing and none is extra.
assert<Equal<keyof typeof Runtime, keyof typeof import("yuke:tui")>>();

// The frame loop gives the public key event, so a view gets what the host sends.
assert<Equal<KeyEvent, Extract<TermEvent, { type: "key" }>>>();

// A patch takes `null` to delete a field; a style does not.
const patch: StylePatch = { fg: null, bold: true, inherits: "title" };
// @ts-expect-error A style has no `null` field.
const style: Style = { fg: null };
// @ts-expect-error A color names the base palette or is an index, `#rrggbb`, or `reset`.
const color: Style = { fg: "red" };

declare const tui: Tui;
// `get("tui")` can be `undefined` outside the terminal interface, so a plugin must check it.
declare const ctx: PluginContext;
const got = ctx.get("tui");
assert<Equal<typeof got, Tui | undefined>>();
// @ts-expect-error `tui` is a service of yuke: a plugin cannot provide it.
ctx.provide("tui", tui);
// A watch takes an inline callback that returns no cleanup.
const watched = tui.widgets.addWatcher((mount) => {
  if (mount.widget.kind === "editor") mount.widget.caret = 0;
});
void [patch, style, color, got, watched];
