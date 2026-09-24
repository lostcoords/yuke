// The public UI kit has no default shell or plugin activation. A plugin shows, registers, and repaints through `ctx.tui`.
export { View, text, fill, copy, quit } from "yuke:core";
export { ui, List, Composer, Text, Window, Picker, Prompt, borders, NAV_KEYS } from "yuke:ui";
export { TextInput } from "yuke:text-input";
export { Pager } from "yuke:pager";
export { Document } from "yuke:md";
export * as layout from "yuke:layout";
export * as keys from "yuke:keys";

/** @typedef {import("./types/core.js").Rect} Rect */
/** @typedef {import("./types/core.js").ViewLike} ViewLike */
/** @typedef {import("./types/layout.js").LayoutNode} LayoutNode */
/** @typedef {import("./types/ext.js").Capabilities["tui"]} Tui */
