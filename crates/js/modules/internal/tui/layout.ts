/** `stack`: a layout of children in a row or a column, on the placement contract of `View`. */
import type { Direction, Placement, Size, StackChild, View } from "yuke:tui";

/**
 * A view that places `children` along `direction`. Sized children take their cells in order, cut to the cells that
 * remain; `fill` children share the rest, and the last one gets the cells of the rounding.
 */
export function stack(direction: Direction, children: readonly StackChild[]): View {
  const items = [...children];
  return Object.freeze({
    layout(size: Size): readonly Placement[] {
      const along = direction === "row" ? size.width : size.height;
      let left = along;
      const cells = items.map((item) => {
        const wanted = item.size;
        if (wanted === "fill") return undefined;
        const asked = typeof wanted === "function" ? wanted(size) : wanted;
        const taken = Math.min(left, Math.max(0, Math.floor(asked)));
        left -= taken;
        return taken;
      });
      const fills = cells.filter((count) => count === undefined).length;
      const share = fills === 0 ? 0 : Math.floor(left / fills);
      const lastFill = cells.lastIndexOf(undefined);
      let at = 0;
      return items.map(({ view }, index) => {
        const count = cells[index] ?? (index === lastFill ? left - share * (fills - 1) : share);
        const start = at;
        at += count;
        return direction === "row"
          ? { view, rect: { column: start, row: 0, width: count, height: size.height } }
          : { view, rect: { column: 0, row: start, width: size.width, height: count } };
      });
    },
    draw(): void {},
  });
}
