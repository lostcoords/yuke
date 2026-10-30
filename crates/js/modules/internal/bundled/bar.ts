/**
 * The bundled plugin `bar`: the status bar in the last row, below the pane tree. It draws the items of `tui.status`.
 * Without room, it drops whole items by priority and cuts the last item that still does not fit.
 */

import type { PluginContext } from "yuke:plugins";
import type { Infer } from "yuke:tools";
import { type Canvas, fit, measure, type StatusItem, stack, type View } from "yuke:tui";

export const optionsSchema = {
  type: "object",
  properties: {
    hide: {
      type: "array",
      items: { type: "string" },
      description: 'The keys of the items that the bar does not show, such as "core:keys".',
    },
    order: {
      type: "array",
      items: { type: "string" },
      description: "Keys in the order to show them. A key in this list takes its place here as its order.",
    },
  },
} as const;

type Options = Infer<typeof optionsSchema>;

const SEPARATOR = " · ";

/** The style group of the bar. */
const STYLE = "bar";

export function apply(ctx: PluginContext<Options>): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const hide = new Set(ctx.options.hide ?? []);
  const order = ctx.options.order ?? [];
  // The bar has no background, so it stays quiet below the panes.
  tui.styles.set(STYLE, { dim: true });
  const bar: View = {
    draw: (canvas) => {
      const items = tui.status
        .list()
        .filter((item) => item.text !== "" && !hide.has(item.key))
        .map((item) => {
          const at = order.indexOf(item.key);
          return at < 0 ? item : { ...item, order: at };
        });
      draw(canvas, fitted(items, canvas.width));
    },
  };
  tui.setRoot(() =>
    stack("column", [
      { view: tui.panes.view, size: "fill" },
      { view: bar, size: 1 },
    ]),
  );
  return undefined;
}

/** The cells of `items` on one side, with the separators. */
function cells(items: readonly StatusItem[]): number {
  return items.reduce((sum, item, at) => sum + measure(item.text) + (at > 0 ? SEPARATOR.length : 0), 0);
}

/** The items that fit in `width`. The lowest priority goes first; of equal priorities, the higher order goes first. */
function fitted(items: readonly StatusItem[], width: number): StatusItem[] {
  let kept = [...items];
  const need = (): number => {
    const left = kept.filter((item) => item.side === "left");
    const right = kept.filter((item) => item.side === "right");
    return cells(left) + cells(right) + (left.length > 0 && right.length > 0 ? 1 : 0);
  };
  while (kept.length > 1 && need() > width) {
    const dropped = kept.reduce((low, item) =>
      item.priority < low.priority || (item.priority === low.priority && item.order >= low.order) ? item : low,
    );
    kept = kept.filter((item) => item !== dropped);
  }
  return kept;
}

/** Draw `items` on the row of `canvas`: the left side from the start, the right side to the end. */
function draw(canvas: Canvas, items: readonly StatusItem[]): void {
  const byOrder = (a: StatusItem, b: StatusItem): number => a.order - b.order || (a.key < b.key ? -1 : 1);
  const left = items.filter((item) => item.side === "left").toSorted(byOrder);
  const right = items.filter((item) => item.side === "right").toSorted(byOrder);
  let column = 0;
  const write = (side: readonly StatusItem[], end: number): void => {
    side.forEach((item, at) => {
      if (at > 0) column = canvas.text(column, 0, SEPARATOR, STYLE);
      const room = end - column;
      // Only the last item that still does not fit gets a cut.
      const text = measure(item.text) <= room ? item.text : `${item.text.slice(0, fit(item.text, room - 1))}…`;
      const style = item.style === undefined ? [] : Array.isArray(item.style) ? item.style : [item.style];
      column = canvas.text(column, 0, text, [STYLE, ...style]);
    });
  };
  write(left, canvas.width);
  column = Math.max(column + (left.length > 0 ? 1 : 0), canvas.width - cells(right));
  write(right, canvas.width);
}
