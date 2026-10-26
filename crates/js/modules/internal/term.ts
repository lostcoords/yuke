/**
 * The terminal of the terminal interface: the frame loop and the cell grid. `term.run` gives the loop an event
 * handler and a draw function. The loop gives each event to the handler, then draws one frame: it blanks the grid,
 * calls `draw`, and writes the changed cells. An event batch draws at once; `requestFrame` asks for a later frame.
 * Offsets in text are UTF-16 units, as in JavaScript strings.
 */
import {
  type TermStyle,
  termBackground,
  termCopy,
  termCursor,
  termFill,
  termFit,
  termGraphemes,
  termMeasure,
  termQuit,
  termReload,
  termRequestFrame,
  termRun,
  termSize,
  termSuspend,
  termText,
  termTruecolor,
  termWrap,
} from "yuke:internal/native";

export type Style = TermStyle;

/**
 * The bits of `mods`: shift 1, alt 2, ctrl 4, super 8, hyper 16, meta 32. A mouse event has the first three.
 */
export type TermEvent =
  /** The first event of a runtime. After a reload, `snapshot` is the text that the old runtime gave `term.reload`. */
  | { readonly type: "start"; readonly snapshot?: string }
  | {
      readonly type: "key";
      /** `char` for a key that types, else a name such as `enter`, `esc`, `up`, `page_down`, or `f5`. */
      readonly code: string;
      /** The character of a `char` key, else "". */
      readonly char: string;
      /** The key with shift on the current layout, from a kitty terminal, else "". */
      readonly shifted: string;
      /** The key at the same place on a US layout, from a kitty terminal, else "". */
      readonly baseLayout: string;
      /** The text that the key types, else "". */
      readonly text: string;
      readonly mods: number;
    }
  | {
      readonly type: "mouse";
      readonly col: number;
      readonly row: number;
      readonly button: string;
      readonly event: "press" | "release" | "motion" | "drag";
      readonly mods: number;
    }
  | { readonly type: "paste"; readonly text: string }
  | { readonly type: "resize"; readonly w: number; readonly h: number }
  | { readonly type: "focus"; readonly focused: boolean }
  | { readonly type: "background"; readonly background: "dark" | "light" }
  /** A notice of the host or of a plugin. `source` is the plugin name, `console`, or `host:…`. */
  | {
      readonly type: "notice";
      readonly level: "debug" | "info" | "warn" | "error";
      readonly source: string;
      readonly text: string;
    };

/** What `term.run` takes. */
export interface Handler {
  event: (event: TermEvent) => void;
  draw: () => void;
}

export const term = {
  /** Start the frame loop. A second call in a runtime throws. The events that came earlier wait for it. */
  run(handler: Handler): void {
    const { event, draw } = handler;
    termRun(
      (value) => event.call(handler, value as TermEvent),
      () => draw.call(handler),
    );
  },
  /** Ask for a frame in `delay` milliseconds. Many asks give one frame, and a frame comes at most 120 times a second. */
  requestFrame(delay = 0): void {
    termRequestFrame(delay);
  },
  /** Blank a rectangle with `style`. The grid clips it. */
  fill(x: number, y: number, width: number, height: number, style?: Style): void {
    termFill(x, y, width, height, style);
  },
  /** Write `text` on one row, clipped at the right edge, and return the column after it. */
  text(x: number, y: number, text: string, style?: Style): number {
    return termText(x, y, text.toWellFormed(), style);
  },
  /** Show the cursor at a cell, or hide it. A frame starts with the cursor hidden. */
  cursor(x: number, y: number, visible = true): void {
    termCursor(x, y, visible);
  },
  /** The cells of `text`. */
  measure(text: string): number {
    return termMeasure(text.toWellFormed());
  },
  /** The offset, the length, and the cells of each grapheme of `text`, three numbers each. */
  graphemes(text: string): Int32Array {
    return termGraphemes(text.toWellFormed());
  },
  /** The UTF-16 length of the longest grapheme prefix of `text` that fits in `cells`. */
  fit(text: string, cells: number): number {
    return termFit(text.toWellFormed(), cells);
  },
  /**
   * The rows of `text` at `width` cells, as `[start, end, soft]` triples. A line end ends a row (soft 0). A soft break
   * (soft 1) comes after the last space when the text from that space fits, else before the grapheme that does not
   * fit. With `head`, only the first `head` rows stay.
   */
  wrap(text: string, width: number, head = 0): Int32Array {
    return termWrap(text.toWellFormed(), width, head);
  },
  /** Send `text` to the clipboard of the terminal with OSC 52. */
  copy(text: string): void {
    termCopy(text.toWellFormed());
  },
  /** Ask the host to quit. */
  quit(): void {
    termQuit();
  },
  /** Ask the host to give the terminal to the shell until the shell resumes yuke. A `resize` event comes after. */
  suspend(): void {
    termSuspend();
  },
  /**
   * Ask the host to load the plugins again. After a reload, a new runtime starts with `snapshot` in its start event, and
   * the current runtime stops. A failed reload keeps the current runtime and sends it a notice.
   */
  reload(snapshot: string): void {
    termReload(snapshot);
  },
  get width(): number {
    return termSize()[0];
  },
  get height(): number {
    return termSize()[1];
  },
  /** The light or dark class of the terminal background. */
  get background(): "dark" | "light" {
    return termBackground();
  },
  /** True when the terminal draws 24-bit color. */
  get truecolor(): boolean {
    return termTruecolor();
  },
};
