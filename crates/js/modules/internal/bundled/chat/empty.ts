/**
 * The header of an empty chat pane: the icon of yuke, its version, the model and the folder of the first message, and
 * the way to start. It draws at the top left of the pane, and the lines move below the icon in a narrow pane. A pane
 * too small for all of it shows nothing.
 */

import { clipped } from "yuke:internal/chat/rows";
import { type Canvas, type CanvasStyle, measure, type Style, type View } from "yuke:tui";

/**
 * The icon, one character per pixel: `.` none, `g` face, `e` eye, `w` highlight. A sextant cell shows 2 x 3 pixels, and
 * a sextant pixel is 4/3 as tall as it is wide, so the grid is the logo at 3/4 of its height.
 */
const ICON = [
  "..ggg..............ggg..",
  "......ggg......ggg......",
  "........gg....gg........",
  "......gggggggggggg......",
  "..gegeeeggggggggeeegeg..",
  "..ewwweeeggggggeeewwwe..",
  "..eeeeeeeeggggeeeeeeee..",
  "..ggeeeeeeggggeeeeeegg..",
  "....ggeeeggggggeeegg....",
  "......gggggggggggg......",
  "........gggggggg........",
  "..........gggg..........",
];

/** The colors of the icon. They stay the same on each background. */
const COLORS: Readonly<Record<string, readonly [number, number, number]>> = {
  g: [0xa8, 0xcf, 0xa0],
  e: [0x26, 0x28, 0x26],
  w: [0xf4, 0xf2, 0xeb],
};

const ICON_WIDTH = (ICON[0]?.length ?? 0) / 2;
const ICON_ROWS = ICON.length / 3;

/** The columns left of the icon, and between the icon and the lines beside it. */
const GAP = 2;

/** The fewest columns for the lines beside the icon. With fewer, the lines go below the icon. */
const BESIDE = 24;

const hex = (color: readonly [number, number, number]): `#${string}` =>
  `#${color.map((part) => part.toString(16).padStart(2, "0")).join("")}`;

const DIM: Style = { dim: true };
const COMMAND: Style = { fg: hex(COLORS.g ?? [0, 0, 0]) };

/** The sextant of `bits`: bit `n` is the pixel `n` of a 2 x 3 cell, row by row. */
function sextant(bits: number): string {
  if (bits === 0) return " ";
  if (bits === 63) return "█";
  // The left and the right half are older block characters, so the sextant block leaves them out.
  if (bits === 21) return "▌";
  if (bits === 42) return "▐";
  return String.fromCodePoint(0x1_fb_00 + bits - 1 - (bits > 21 ? 1 : 0) - (bits > 42 ? 1 : 0));
}

const distance = (a: readonly number[], b: readonly number[]): number =>
  a.reduce((sum, part, index) => sum + (part - (b[index] ?? 0)) ** 2, 0);

/**
 * The cell of the 2 x 3 pixels `pixels`. The most common color draws the sextant. The second one fills the cell, unless
 * a pixel is empty, which shows the background. A third color takes the nearer of the two.
 */
function sextantCell(pixels: readonly string[]): readonly [string, Style | undefined] {
  const counts = new Map<string, number>();
  for (const pixel of pixels) if (pixel !== ".") counts.set(pixel, (counts.get(pixel) ?? 0) + 1);
  const ranked = [...counts.keys()].sort((a, b) => (counts.get(b) ?? 0) - (counts.get(a) ?? 0));
  const fg = ranked[0];
  if (fg === undefined) return [" ", undefined];
  const bg = pixels.includes(".") ? undefined : ranked[1];
  const fgColor = COLORS[fg] ?? [0, 0, 0];
  const lit = (pixel: string): boolean => {
    if (pixel === fg) return true;
    if (pixel === "." || pixel === bg) return false;
    const color = COLORS[pixel] ?? [0, 0, 0];
    return bg === undefined || distance(color, fgColor) <= distance(color, COLORS[bg] ?? [0, 0, 0]);
  };
  const bits = pixels.reduce((sum, pixel, index) => sum + (lit(pixel) ? 1 << index : 0), 0);
  const style: Style = bg === undefined ? { fg: hex(fgColor) } : { fg: hex(fgColor), bg: hex(COLORS[bg] ?? [0, 0, 0]) };
  return [sextant(bits), style];
}

const CELLS = Array.from({ length: ICON_ROWS }, (_, row) =>
  Array.from({ length: ICON_WIDTH }, (_, column) =>
    sextantCell([0, 1, 2].flatMap((dy) => [0, 1].map((dx) => ICON[3 * row + dy]?.[2 * column + dx] ?? "."))),
  ),
);

/** One part of a line, with its style. */
type Part = readonly [string, CanvasStyle];

/** What the header shows of one pane. Each read gives the state now. */
interface EmptyHeaderSource {
  readonly version: string;
  /** The model with its level, and the folder, of the first message of the pane. */
  readonly target: () => { readonly model?: string | undefined; readonly folder?: string | undefined };
  /** A provider is ready, so a message can go out. */
  readonly ready: () => boolean;
  /** Draw the icon. A terminal without sextant glyphs shows the lines alone. */
  readonly icon: boolean;
}

/** The lines of the header. */
function lines(source: EmptyHeaderSource): readonly (readonly Part[])[] {
  const target = source.target();
  const place = [target.model, target.folder].filter((text) => text !== undefined).join(" · ");
  const start: readonly Part[] = source.ready()
    ? [
        ["Type ", DIM],
        ["/", COMMAND],
        [" for commands", DIM],
      ]
    : [
        ["Type ", DIM],
        ["/login", COMMAND],
        [" to connect a provider", DIM],
      ];
  return [
    [
      ["yuke", { bold: true }],
      [` ${source.version}`, DIM],
    ],
    ...(place === "" ? [] : [[[place, DIM] as const]]),
    start,
  ];
}

/** Draw `parts` from `column` on `row` within `room` columns. A longer line shows dim and cut with `…`. */
function drawLine(canvas: Canvas, column: number, row: number, room: number, parts: readonly Part[]): void {
  const text = parts.map((part) => part[0]).join("");
  if (measure(text) > room) {
    canvas.text(column, row, clipped(text, room), DIM);
    return;
  }
  let at = column;
  for (const [words, style] of parts) at = canvas.text(at, row, words, style);
}

/** The default header of an empty chat pane. */
export function emptyHeader(source: EmptyHeaderSource): View {
  return {
    draw(canvas: Canvas): void {
      const shown = lines(source);
      if (!source.icon) {
        if (canvas.height < 1 + shown.length || canvas.width < GAP + 1) return;
        for (const [index, parts] of shown.entries()) drawLine(canvas, GAP, 1 + index, canvas.width - GAP - 1, parts);
        return;
      }
      const beside = canvas.width - GAP - ICON_WIDTH - GAP - 1;
      const below = beside < BESIDE;
      // All or nothing: the top row, the icon, and the lines beside it or below it after one empty row.
      const height = 1 + ICON_ROWS + (below ? 1 + shown.length : 0);
      if (canvas.height < height || canvas.width < GAP + ICON_WIDTH + 1) return;
      for (const [row, cells] of CELLS.entries()) {
        for (const [column, [character, style]] of cells.entries()) {
          if (style !== undefined) canvas.text(GAP + column, 1 + row, character, style);
        }
      }
      if (below) {
        for (const [index, parts] of shown.entries()) {
          drawLine(canvas, GAP, 1 + ICON_ROWS + 1 + index, canvas.width - GAP - 1, parts);
        }
        return;
      }
      const first = 1 + Math.floor((ICON_ROWS - shown.length) / 2);
      for (const [index, parts] of shown.entries()) {
        drawLine(canvas, GAP + ICON_WIDTH + GAP, first + index, beside, parts);
      }
    },
  };
}
