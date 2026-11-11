/**
 * The canvas of a view: local cells over a screen origin, cut to a clip rect.
 * A view uses a canvas during its draw call.
 */
import type { TermStyle } from "yuke:internal/native";
import { termGraphemes, termMeasure } from "yuke:internal/native";
import type { Canvas, CanvasStyle, Rect } from "yuke:tui";

/** What a canvas writes to: the screen in absolute cells. */
export interface Screen {
  /** Write the part of `text` that ends at or before the column `right`, and return the column after the whole text. */
  readonly text: (column: number, row: number, text: string, style: TermStyle, right: number) => number;
  readonly fill: (column: number, row: number, width: number, height: number, style: TermStyle) => void;
  /** The cell style of a style or of a list of styles: a later style wins per field. See `Styles.cell`. */
  readonly resolve: (style: CanvasStyle | undefined) => TermStyle;
}

/** The canvas of the screen rect `rect`, cut to `clip`, both in absolute cells. `base` comes before each style. */
export function createCanvas(screen: Screen, rect: Rect, clip: Rect, base?: CanvasStyle): Canvas {
  return Object.freeze({
    width: rect.width,
    height: rect.height,
    text(column: number, row: number, text: string, style?: CanvasStyle): number {
      const value = text.toWellFormed();
      const cell = screen.resolve(layered(base, style));
      return writeText(screen, clip, rect.column + column, rect.row + row, value, cell) - rect.column;
    },
    fill(column: number, row: number, width: number, height: number, style?: CanvasStyle): void {
      const cut = intersect(clip, { column: rect.column + column, row: rect.row + row, width, height });
      if (cut.width > 0 && cut.height > 0) {
        screen.fill(cut.column, cut.row, cut.width, cut.height, screen.resolve(layered(base, style)));
      }
    },
    region(column: number, row: number, width: number, height: number): Canvas {
      const part = {
        column: rect.column + column,
        row: rect.row + row,
        width: Math.max(0, width),
        height: Math.max(0, height),
      };
      return createCanvas(screen, part, intersect(clip, part), base);
    },
  });
}

/** `over` on top of `under`: a later style wins per field. */
export function layered(under: CanvasStyle | undefined, over: CanvasStyle | undefined): CanvasStyle | undefined {
  if (under === undefined || over === undefined) return over ?? under;
  return [under, over].flat() as CanvasStyle;
}

/** The part of `a` inside `b`; an empty part has a width or a height of 0. */
export function intersect(a: Rect, b: Rect): Rect {
  const column = Math.max(a.column, b.column);
  const row = Math.max(a.row, b.row);
  const right = Math.min(a.column + a.width, b.column + b.width);
  const bottom = Math.min(a.row + a.height, b.row + b.height);
  return { column, row, width: Math.max(0, right - column), height: Math.max(0, bottom - row) };
}

/**
 * Write `text` from the screen cell (`column`, `row`), cut to `clip`, and return the screen column after the whole text.
 * A wide grapheme cut at the left gives spaces.
 */
function writeText(screen: Screen, clip: Rect, column: number, row: number, text: string, style: TermStyle): number {
  const right = clip.column + clip.width;
  if (row < clip.row || row >= clip.row + clip.height || column >= right) return column + termMeasure(text);
  if (column >= clip.column) return screen.text(column, row, text, style, right);
  const triples = termGraphemes(text);
  let cells = 0;
  let offset = text.length;
  for (let at = 0; at < triples.length; at += 3) {
    if (column + cells >= clip.column) {
      offset = triples[at] ?? text.length;
      break;
    }
    cells += triples[at + 2] ?? 0;
  }
  if (column + cells < clip.column) return column + cells;
  // A wide grapheme across the left edge leaves its visible cells blank.
  const shown = " ".repeat(column + cells - clip.column) + text.slice(offset);
  return screen.text(clip.column, row, shown, style, right);
}
