// The public UI kit has no default shell or plugin activation.
export { View, Node, root, style, text, fill, copy, quit, suspend } from "yuke:core";
export { ui, List, Composer, Text, Window, Picker, Prompt, borders, NAV_KEYS } from "yuke:ui";
export { TextInput } from "yuke:text-input";
export { Pager } from "yuke:pager";
export { Document } from "yuke:md";
export { term } from "yuke:term";
export * as layout from "yuke:layout";
export * as keys from "yuke:keys";

/** @typedef {import("./types/core.js").Rect} Rect */
/** @typedef {import("./types/core.js").ViewLike} ViewLike */
/** @typedef {import("./types/layout.js").LayoutNode} LayoutNode */
/** @typedef {import("./types/ext.js").Capabilities["tui"]} Tui */
