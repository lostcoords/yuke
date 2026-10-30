/**
 * The bundled plugin `toasts`: the notices of the core as a stack at the top right. Info leaves after 4 s, a warning or
 * an error stays until a dismissal, and debug shows no toast.
 */

import type { PluginContext } from "yuke:plugins";
import { fit, type Notice, type PaletteColor, Picker, type Size, type Style, type View, wrap } from "yuke:tui";

/** The screen shows at most this many toasts. A new one drops the oldest info toast, else the oldest toast. */
const MOST = 4;

const INFO_MS = 4000;

/** The text of one toast takes at most this many rows. */
const BODY_ROWS = 3;

/** The history picker takes at most this many rows. */
const HISTORY_ROWS = 16;

const COLOR: Readonly<Record<Notice["level"], PaletteColor>> = {
  debug: "surfaceFg",
  info: "accent",
  warn: "warn",
  error: "danger",
};

/** A notice on the screen. `count` counts its equal notices, and `cancel` stops its timer. */
interface Toast {
  readonly notice: Notice;
  count: number;
  cancel: (() => void) | undefined;
}

export function apply(ctx: PluginContext): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const toasts: Toast[] = [];

  const remove = (toast: Toast | undefined): void => {
    const at = toast === undefined ? -1 : toasts.indexOf(toast);
    if (at < 0) return;
    toasts.splice(at, 1);
    toast?.cancel?.();
  };

  const show = (notice: Notice): void => {
    if (notice.level === "debug") return;
    let toast = toasts.find(
      (shown) =>
        shown.notice.level === notice.level &&
        shown.notice.source === notice.source &&
        shown.notice.text === notice.text &&
        shown.notice.sessionId === notice.sessionId,
    );
    if (toast !== undefined) toast.count += 1;
    else {
      if (toasts.length === MOST) remove(toasts.find((shown) => shown.notice.level === "info") ?? toasts[0]);
      // A notice from the history before the load can count repeats already.
      toast = { notice, count: notice.count, cancel: undefined };
      toasts.push(toast);
    }
    if (notice.level === "info") {
      // A repeat starts the wait again.
      const shown = toast;
      shown.cancel?.();
      shown.cancel = tui.after(INFO_MS, () => remove(shown));
    }
  };

  /** Give the width of the stack on a screen of `size`. */
  const widthOf = (size: Size): number =>
    Math.max(0, Math.min(size.width - 2, Math.max(24, Math.min(60, Math.round(size.width * 0.4)))));

  /** Give the title and the body rows of `toast`. A row has a bar, a space, the text, and one cell of padding. */
  const rowsOf = (toast: Toast, width: number): string[] => {
    const room = Math.max(1, width - 3);
    const title = `${toast.notice.source}${toast.count > 1 ? ` ×${toast.count}` : ""}`;
    const text = toast.notice.text;
    const spans = wrap(text, room, BODY_ROWS + 1);
    const body: string[] = [];
    for (let at = 0; at < spans.length && body.length < BODY_ROWS; at += 3) {
      body.push(text.slice(spans[at], spans[at + 1]));
    }
    const last = body.length - 1;
    if (spans.length > BODY_ROWS * 3 && last >= 0) {
      const row = body[last] ?? "";
      body[last] = `${row.slice(0, fit(row, room - 1))}…`;
    }
    return [title.slice(0, fit(title, room)), ...body];
  };

  const heightOf = (width: number): number =>
    toasts.reduce((sum, toast, at) => sum + rowsOf(toast, width).length + (at > 0 ? 1 : 0), 0);

  const stack: View = {
    draw: (canvas) => {
      let row = 0;
      for (const toast of toasts) {
        const color = COLOR[toast.notice.level];
        rowsOf(toast, canvas.width).forEach((text, at) => {
          canvas.fill(0, row, canvas.width, 1, { bg: "surface" });
          canvas.text(0, row, "▌", { fg: color, bg: "surface" });
          const style: Style = at === 0 ? { fg: color, bg: "surface", bold: true } : { fg: "surfaceFg", bg: "surface" };
          canvas.text(2, row, text, style);
          row += 1;
        });
        row += 1;
      }
    },
    // A left press on a toast dismisses it.
    mouse: (event) => {
      if (event.action !== "press" || event.button !== "left") return false;
      let top = 0;
      for (const toast of toasts) {
        const height = rowsOf(toast, widthOf({ width: tui.width, height: tui.height })).length;
        if (event.row >= top && event.row < top + height) {
          remove(toast);
          return true;
        }
        top += height + 1;
      }
      return false;
    },
  };
  tui.overlay(() => stack, {
    modal: false,
    place: (size) => {
      const width = widthOf(size);
      return { column: size.width - width - 1, row: 1, width, height: heightOf(width) };
    },
  });

  tui.commands.add({
    name: "dismiss",
    description: "Dismiss the toasts",
    run: () => {
      for (const toast of [...toasts]) remove(toast);
      tui.requestFrame();
    },
  });
  tui.keys.bind("ctrl+l", "dismiss");
  tui.commands.add({
    name: "history",
    description: "Show the notices",
    run: () => {
      const notices = tui.notices.list().toReversed();
      const mount = tui.overlay(
        () =>
          new Picker<Notice>({
            items: notices,
            key: (notice) => String(notices.indexOf(notice)),
            label: (notice) =>
              `${notice.level} ${notice.source}${notice.count > 1 ? ` ×${notice.count}` : ""}: ${notice.text.split("\n")[0]}`,
            detail: (notice) => notice.sessionId ?? "",
            choose: () => mount.close(),
            cancel: () => mount.close(),
          }),
        {
          place: (size) => {
            const height = Math.min(HISTORY_ROWS, size.height);
            return { column: 0, row: size.height - height, width: size.width, height };
          },
        },
      );
    },
  });

  // The warnings and errors of the history show too, such as a fault of a plugin that loaded earlier.
  for (const notice of tui.notices.list()) if (notice.level === "warn" || notice.level === "error") show(notice);
  tui.notices.on(show);
  return undefined;
}
