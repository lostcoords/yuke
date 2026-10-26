/**
 * The canvas of a view: local cells over a screen origin, cut to a clip rect. A view gets a canvas for one draw call,
 * and the canvas throws after that call.
 */
import type { TermStyle } from "yuke:internal/native";
import { termFit, termGraphemes, termMeasure } from "yuke:internal/native";
import type { Canvas, Rect, Style } from "yuke:tui";

/** What a canvas writes to: the screen in absolute cells. */
export interface Screen {
  readonly text: (column: number, row: number, text: string, style: TermStyle) => void;
  readonly fill: (column: number, row: number, width: number, height: number, style: TermStyle) => void;
  readonly resolve: (style: string | Style | undefined) => TermStyle;
}

/** The draw call that a canvas belongs to: `open` is false once the call returns. */
export interface DrawCall {
  open: boolean;
}

/** The canvas of the screen rect `rect`, cut to `clip`, both in absolute cells. */
export function createCanvas(screen: Screen, rect: Rect, clip: Rect, call: DrawCall): Canvas {
  const checkOpen = (): void => {
    if (!call.open) throw new TypeError("a canvas is valid only during the draw call that gets it");
  };
  return Object.freeze({
    width: rect.width,
    height: rect.height,
    text(column: number, row: number, text: string, style?: string | Style): number {
      checkOpen();
      const value = String(text).toWellFormed();
      const end = column + termMeasure(value);
      writeText(screen, clip, rect.column + column, rect.row + row, value, screen.resolve(style));
      return end;
    },
    fill(column: number, row: number, width: number, height: number, style?: string | Style): void {
      checkOpen();
      const cut = intersect(clip, { column: rect.column + column, row: rect.row + row, width, height });
      if (cut.width > 0 && cut.height > 0) {
        screen.fill(cut.column, cut.row, cut.width, cut.height, screen.resolve(style));
      }
    },
    region(column: number, row: number, width: number, height: number): Canvas {
      checkOpen();
      const part = {
        column: rect.column + column,
        row: rect.row + row,
        width: Math.max(0, width),
        height: Math.max(0, height),
      };
      return createCanvas(screen, part, intersect(clip, part), call);
    },
  });
}

/** The part of `a` inside `b`; an empty part has a width or a height of 0. */
export function intersect(a: Rect, b: Rect): Rect {
  const column = Math.max(a.column, b.column);
  const row = Math.max(a.row, b.row);
  const right = Math.min(a.column + a.width, b.column + b.width);
  const bottom = Math.min(a.row + a.height, b.row + b.height);
  return { column, row, width: Math.max(0, right - column), height: Math.max(0, bottom - row) };
}

/** Write `text` from the screen cell (`column`, `row`), cut to `clip`. A wide grapheme cut at the left gives spaces. */
function writeText(screen: Screen, clip: Rect, column: number, row: number, text: string, style: TermStyle): void {
  const right = clip.column + clip.width;
  if (row < clip.row || row >= clip.row + clip.height || column >= right || text === "") return;
  let start = column;
  let shown = text;
  if (start < clip.column) {
    const triples = termGraphemes(text);
    let cells = 0;
    let offset = text.length;
    for (let at = 0; at < triples.length; at += 3) {
      if (start + cells >= clip.column) {
        offset = triples[at] ?? text.length;
        break;
      }
      cells += triples[at + 2] ?? 0;
    }
    if (start + cells < clip.column) return;
    // A wide grapheme across the left edge leaves its visible cells blank.
    shown = " ".repeat(start + cells - clip.column) + text.slice(offset);
    start = clip.column;
  }
  const length = termFit(shown, right - start);
  if (length > 0) screen.text(start, row, shown.slice(0, length), style);
}
