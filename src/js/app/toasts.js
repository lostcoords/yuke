// Show each notification as a toast at the top right, and show the notification history on request.
import { contains, root } from "yuke:internal/core";
import { notifications, notify } from "yuke:internal/kernel";
import { clip, wrapPreview } from "yuke:internal/text-input";
import { RowsView, Text, Window } from "yuke:internal/ui";

/** @import { Context } from "yuke:internal/ext" */
/** @import { HostMouseEvent, Rect } from "./types/core.js" */
/** @import { TranscriptRow } from "./types/pager.js" */
/** @import { Notification } from "./types/ext.js" */
/** @import { WindowOptions } from "./types/ui.js" */

/** @type {Record<Wire.NoticeLevel, string>} */
const LEVEL_GROUP = { info: "NotifyInfo", warn: "NotifyWarn", error: "NotifyError" };
// An info toast leaves after this time. A warning and an error stay until the user dismisses them.
const INFO_MS = 4000;
// The history keeps up to 100 entries, so the screen shows only the newest few toasts.
const MAX_TOASTS = 4;
// A toast shows the start of a long message. The history shows all of it.
const TOAST_ROWS = 3;
const TOAST_WIDTH_MIN = 24;
const TOAST_WIDTH_MAX = 60;
const TOAST_PADDING = Object.freeze({ x: 1, y: 0 });

/** @param {Readonly<Notification>} n @returns {string} */
function titleOf(n) {
  return n.source + (n.count > 1 ? " ×" + n.count : "");
}

// A toast floats over the panes and takes no key. A click anywhere on it dismisses it.
class ToastWindow extends Window {
  /** @param {WindowOptions} opts @param {() => void} onDismiss */
  constructor(opts, onDismiss) {
    super(opts);
    this.onDismiss = onDismiss;
  }

  /** @param {HostMouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    if (ev.event !== "press" || !contains(this.rect, ev.col, ev.row)) return false;
    this.onDismiss();
    return true;
  }
}

/** @typedef {{ entry: Readonly<Notification>, win: ToastWindow, timer: number }} Toast */

// The history, newest first. Each entry shows its level and source, then its message, then its stack.
/** @param {number} width @returns {TranscriptRow[]} */
function historyRows(width) {
  /** @type {TranscriptRow[]} */
  const rows = [];
  for (let i = notifications.length - 1; i >= 0; i--) {
    const n = /** @type {Notification} */ (notifications[i]);
    if (rows.length) rows.push({ text: "" });
    rows.push({ text: n.level + " · " + titleOf(n), group: LEVEL_GROUP[n.level] });
    for (const row of wrapPreview(n.message, width, 0).rows) rows.push({ text: n.message.slice(row.start, row.end), group: "UIBody" });
    for (const line of n.stack.split("\n")) if (line.trim() !== "") rows.push({ text: clip(line.trim(), width), group: "UIDim" });
  }
  if (rows.length === 0) rows.push({ text: "no notifications", group: "UIDim" });
  return rows;
}

export const toastsPlugin = {
  name: "toasts",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // An unload removes the groups with the toasts that use them.
      ctx.tui.style.add({
        NotifyInfo: { fg: "fg", dim: true },
        NotifyWarn: { fg: "fg", bold: true },
        NotifyError: { fg: "danger", bold: true },
      });

      // The toasts in screen order, oldest first. The newest toast shows at the bottom of the stack.
      /** @type {Toast[]} */
      const shown = [];

      // The overlays lay out in push order, so the toasts above this one already have their height.
      /** @param {Toast} toast @param {Rect} bounds @param {number} w @returns {{ x: number, y: number }} */
      const place = (toast, bounds, w) => {
        let y = bounds.y + 1;
        for (const t of shown) {
          if (t === toast) break;
          y += t.win.rect.h;
        }
        return { x: bounds.x + bounds.w - w - 1, y };
      };

      /** @param {Toast} toast @returns {void} */
      const arm = (toast) => {
        clearTimeout(toast.timer);
        if (toast.entry.level === "info") toast.timer = setTimeout(() => root.popOverlay(toast.win), INFO_MS);
      };

      /** @param {Readonly<Notification>} entry @returns {void} */
      const show = (entry) => {
        // A repeat of a shown entry increases its count, so its toast stays and shows the new count.
        const held = shown.find((t) => t.entry === entry);
        if (held) {
          arm(held);
          root.invalidate();
          return;
        }
        // A full stack drops the oldest info toast first, so an error stays on the screen.
        if (shown.length === MAX_TOASTS) root.popOverlay((shown.find((t) => t.entry.level === "info") ?? /** @type {Toast} */ (shown[0])).win);
        const body = new Text({ text: entry.message, group: "UIBody" });
        const group = LEVEL_GROUP[entry.level];
        /** @type {Toast} */
        const toast = { entry, win: /** @type {ToastWindow} */ (/** @type {unknown} */ (null)), timer: 0 };
        toast.win = new ToastWindow({
          name: "toast",
          modal: false,
          border: "rounded",
          padding: TOAST_PADDING,
          panelGroup: "UIFloat",
          borderGroup: group,
          titleGroup: group,
          title: () => titleOf(entry),
          width: (max) => Math.min(TOAST_WIDTH_MAX, Math.max(TOAST_WIDTH_MIN, Math.floor(max * 0.4))),
          contentHeight: (_max, width) => Math.min(TOAST_ROWS, body.measure(width).h),
          place: (bounds, w) => place(toast, bounds, w),
          content: body,
        }, () => root.popOverlay(toast.win));
        shown.push(toast);
        // Any close of the overlay, by a click, a timer, ctrl+l, or an unload, drops the toast and its timer.
        ctx.tui.overlay(toast.win, () => {
          clearTimeout(toast.timer);
          shown.splice(shown.indexOf(toast), 1);
        });
        arm(toast);
      };

      // A fault before the TUI started, such as a broken index.js, still shows. An old info entry stays in the history only.
      for (const n of notifications) if (n.level !== "info") show(n);
      ctx.on("notify.posted", show);
      // An engine notice names no plugin of this host, so the TUI adds it to the history here. A headless frontend gets it on the wire.
      ctx.on("notice", (ev) => {
        for (const n of ev.notices ?? []) notify(n.level, n.message, n.source);
      });

      ctx.tui.command.add("notify:dismiss", {
        desc: "dismiss every toast",
        run: () => {
          for (const t of shown.slice()) root.popOverlay(t.win);
        },
      });
      ctx.tui.command.add("notify:history", {
        desc: "show the notification history",
        slash: "messages",
        run: () => {
          // A new entry while the view is open builds the rows again at the next layout.
          const content = new RowsView(historyRows, () => root.popOverlay(win));
          const win = new Window({ title: "notifications", footer: "j/k scroll · pgup/pgdn · esc close", border: "rounded", width: (max) => Math.round(max * 0.9), height: (max) => Math.round(max * 0.85), content });
          const unwatch = ctx.on("notify.posted", () => content.refresh());
          ctx.tui.overlay(win, unwatch);
        },
      });
      ctx.tui.keymap.add({ "ctrl+l": "notify:dismiss" });
    });
  },
};
