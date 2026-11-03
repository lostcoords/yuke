// The view of `tui.dialog`: an optional head row, a body, and a footer of the keys that work now. The body gets each key first,
// and the dialog gets what the body leaves, as the scene routes a key from the focused view up to its parents.

import { parseKeys, strokeOf } from "yuke:internal/tui/keys";
import type { DialogKey, DialogOptions, Size, View } from "yuke:tui";

const TITLE = "dialog.title";
const KEYS = "dialog.keys";

/** The rows that one press of each scroll key moves, as a part of the body height for a page. */
const STEPS: Readonly<Record<string, (page: number) => number>> = {
  up: () => -1,
  down: () => 1,
  page_up: (page) => -page,
  page_down: (page) => page,
};

/** The scroll of `body`: a text view has a scroll control, and a scroll list scrolls itself. */
function scrollOf(body: View): ((rows: number) => void) | undefined {
  const view = body as { readonly scroll?: { readonly scrollBy?: unknown }; readonly scrollBy?: unknown };
  const control = view.scroll?.scrollBy;
  if (typeof control === "function") return (rows) => control.call(view.scroll, rows);
  const own = view.scrollBy;
  return typeof own === "function" ? (rows) => own.call(view, rows) : undefined;
}

/** The stroke of the key spec of `key`. A dialog key is one stroke. */
function strokeOfSpec(key: DialogKey): string {
  const strokes = parseKeys(key.key);
  if (strokes.length !== 1) throw new TypeError(`dialog: the key '${key.key}' is not one stroke`);
  return strokes[0] as string;
}

/** The view of a dialog with `options`. */
export function dialogView(options: DialogOptions): View {
  const keys = (options.keys ?? []).map((key) => ({ key, stroke: strokeOfSpec(key) }));
  const active = () => keys.filter((entry) => entry.key.when?.() ?? true);
  const scroll = scrollOf(options.body);
  const head = options.title === undefined ? 0 : 1;
  let bodyHeight = 0;
  const body = options.body;
  return {
    focusable: true,
    // The scene follows one `initialFocus`, so a picker body hands its search field here. A body that cannot take the
    // focus, such as a scroll list, leaves it on the dialog, which still gets each key.
    initialFocus: body.initialFocus ?? (body.focusable === true ? body : undefined),
    layout: (size: Size) => {
      bodyHeight = Math.max(0, size.height - head - 1);
      return [{ view: body, rect: { column: 0, row: head, width: size.width, height: bodyHeight } }];
    },
    draw: (canvas) => {
      if (options.title !== undefined) canvas.text(1, 0, options.title(), TITLE);
      const shown = active();
      const hints: { keys: string; label: string }[] = [];
      for (const entry of shown) {
        const last = hints.at(-1);
        if (last?.label === entry.key.label) last.keys += `/${entry.key.key}`;
        else hints.push({ keys: entry.key.key, label: entry.key.label });
      }
      if (!shown.some((entry) => entry.stroke === "esc")) hints.push({ keys: "esc", label: "close" });
      canvas.text(1, canvas.height - 1, hints.map((hint) => `${hint.keys}: ${hint.label}`).join(" · "), KEYS);
    },
    key: (event) => {
      const stroke = strokeOf(event);
      const entry = active().find((candidate) => candidate.stroke === stroke);
      if (entry !== undefined) {
        entry.key.run();
        return true;
      }
      const step = STEPS[stroke];
      if (scroll === undefined || step === undefined) return false;
      scroll(step(Math.max(1, bodyHeight - 1)));
      return true;
    },
  };
}
