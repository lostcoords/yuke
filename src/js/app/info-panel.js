import { Window, ScrollView } from "yuke:internal/ui";

/** @import { InjectContext } from "./types/ext.js" */

// A two-column information panel shares the cache and context window layout, and scrolls when the rows exceed it.
/** @param {InjectContext<"tui">} ctx @param {string} title @param {[string, string][]} rows @returns {void} */
export function showInfo(ctx, title, rows) {
  const view = new ScrollView(() => close());
  const column = Math.max(12, ...rows.map(([label]) => label.length + 1));
  view.pager.setRows(rows.map(([label, value]) => ({ segments: [{ text: label.padEnd(column), group: "UIDim" }, { text: value, group: "UIQuery" }] })));
  view.pager.toTop();
  const win = new Window({ title, footer: "j/k scroll · esc close", border: "rounded", width: max => Math.round(max * 0.6), contentHeight: rows.length, content: view });
  const close = ctx.tui.overlay(win);
}
