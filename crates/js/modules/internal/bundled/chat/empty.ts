/**
 * The header of an empty chat pane: the icon of yuke, its version, the model and the folder of the first message, and
 * the way to start. It draws at the top left of the pane, and the lines move below the icon in a narrow pane. A pane
 * too small for all of it shows nothing.
 */

import { clipped } from "yuke:internal/chat/rows";
import { type Canvas, type CanvasStyle, measure, type Style, type View } from "yuke:tui";

/** The icon, one character per pixel: `.` none, `g` face, `e` eye, `w` highlight. Two pixel rows make one cell row. */
const ICON = [
  ".gg............gg.",
  "...ggg......ggg...",
  "......gg..gg......",
  "....gggggggggg....",
  "..ggeeggggggeegg..",
  ".gewweeggggeewweg.",
  ".geeeeeggggeeeeeg.",
  "..geeeeggggeeeeg..",
  "...geeeggggeeeg...",
  ".....gggggggg.....",
  "......gggggg......",
  "........gg........",
];

/** The colors of the icon. They stay the same on each background. */
const COLORS: Readonly<Record<string, `#${string}`>> = { g: "#a8cfa0", e: "#262826", w: "#f4f2eb" };

const ICON_WIDTH = 18;
const ICON_ROWS = ICON.length / 2;

/** The columns left of the icon, and between the icon and the lines beside it. */
const GAP = 2;

/** The fewest columns for the lines beside the icon. With fewer, the lines go below the icon. */
const BESIDE = 24;

const DIM: Style = { dim: true };
const COMMAND: Style = { fg: COLORS.g };

/** The cells of one icon row: the character and the style of each column, from the pixel rows `top` and `bottom`. */
function iconCells(top: string, bottom: string): readonly (readonly [string, Style | undefined])[] {
  return [...top].map((pixel, column) => {
    const upper = COLORS[pixel];
    const lower = COLORS[bottom[column] ?? "."];
    if (upper === undefined && lower === undefined) return [" ", undefined] as const;
    if (upper === lower) return ["█", { fg: upper }] as const;
    if (lower === undefined) return ["▀", { fg: upper }] as const;
    if (upper === undefined) return ["▄", { fg: lower }] as const;
    return ["▀", { fg: upper, bg: lower }] as const;
  });
}

const CELLS = Array.from({ length: ICON_ROWS }, (_, row) => iconCells(ICON[2 * row] ?? "", ICON[2 * row + 1] ?? ""));

/** One part of a line, with its style. */
type Part = readonly [string, CanvasStyle];

/** What the header shows of one pane. Each read gives the state now. */
export interface EmptyHeaderSource {
  readonly version: string;
  /** The model with its level, and the folder, of the first message of the pane. */
  readonly target: () => { readonly model?: string | undefined; readonly folder?: string | undefined };
  /** A provider is ready, so a message can go out. */
  readonly ready: () => boolean;
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
