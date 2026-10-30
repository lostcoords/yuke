// A fake terminal for the tests of the terminal interface: a 20×6 driver with a cell grid, and key and mouse events.

import { ManualClock } from "yuke:internal/tui/clock";
import { Core, type Driver } from "yuke:internal/tui/core";
import type { Cursor, KeyCode, KeyEvent, Modifiers, MouseButton, MouseEvent } from "yuke:tui";

const WIDTH = 20;
const HEIGHT = 6;

/** A driver that draws into a grid and records what the core asks of the terminal. */
export interface Terminal {
  readonly driver: Driver;
  /**
   * What the core asks of the terminal. `quit` and `suspend` come by name, a reload with its snapshot, and a copy with
   * its text.
   */
  readonly calls: unknown[];
  /** The cursor of each frame: a point, or `undefined` when the frame hides it. */
  readonly cursors: (Cursor | undefined)[];
  /** The number of frame requests so far. */
  readonly requests: () => number;
  /** The clock of the timers of the core. */
  readonly clock: ManualClock;
  /** Draw a frame of `core` on a blank grid, and give its rows, trimmed at the end. */
  readonly screen: (core: Core) => string[];
}

/** A new terminal with a blank grid. */
export function fakeTerminal(): Terminal {
  const grid = Array.from({ length: HEIGHT }, () => Array<string>(WIDTH).fill(" "));
  const calls: unknown[] = [];
  const cursors: (Cursor | undefined)[] = [];
  let requests = 0;
  const clock = new ManualClock();
  const put = (column: number, row: number, character: string): void => {
    const cells = grid[row];
    if (cells !== undefined && column >= 0 && column < WIDTH) cells[column] = character;
  };
  const driver: Driver = {
    width: () => WIDTH,
    height: () => HEIGHT,
    background: () => "dark",
    truecolor: () => true,
    text: (column, row, text) => {
      [...text].forEach((character, at) => {
        put(column + at, row, character);
      });
    },
    fill: (column, row, width, height) => {
      for (let r = row; r < row + height; r += 1) for (let c = column; c < column + width; c += 1) put(c, r, " ");
    },
    cursor: (point) => {
      cursors.push(point);
    },
    requestFrame: () => {
      requests += 1;
    },
    after: clock.after,
    quit: () => {
      calls.push("quit");
    },
    suspend: () => {
      calls.push("suspend");
    },
    reload: (snapshot) => {
      calls.push(["reload", JSON.parse(snapshot)]);
    },
    copy: (text) => {
      calls.push(["copy", text]);
    },
    readImage: async () => undefined,
    startup: () => ({ cwd: "/work" }),
  };
  return {
    driver,
    calls,
    cursors,
    requests: () => requests,
    clock,
    screen: (core) => {
      for (const row of grid) row.fill(" ");
      core.draw();
      return grid.map((row) => row.join("").trimEnd());
    },
  };
}

/** A new core on the driver of `terminal`, without a default pane. */
export function newCore(terminal: Terminal): Core {
  return new Core(terminal.driver);
}

const NONE: Modifiers = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };

/**
 * The key event of `character` with `modifiers`. It types `character` without ctrl, alt, or super. `extra` sets other
 * fields, such as `shifted`.
 */
export function key(character: string, modifiers: Partial<Modifiers> = {}, extra: Partial<KeyEvent> = {}): KeyEvent {
  return {
    type: "key",
    code: "character",
    character,
    shifted: "",
    baseLayout: "",
    text: modifiers.ctrl || modifiers.alt || modifiers.super ? "" : character,
    modifiers: { ...NONE, ...modifiers },
    ...extra,
  };
}

/** The key event of the named key `code`. */
export function named(code: KeyCode, modifiers: Partial<Modifiers> = {}): KeyEvent {
  return {
    type: "key",
    code,
    character: "",
    shifted: "",
    baseLayout: "",
    text: "",
    modifiers: { ...NONE, ...modifiers },
  };
}

/** A mouse event at a screen cell. */
export function click(
  column: number,
  row: number,
  action: MouseEvent["action"] = "press",
  button: MouseButton = "left",
): MouseEvent {
  return { type: "mouse", column, row, button, action, modifiers: NONE };
}

/** The active context atoms of `core` after a layout. */
export function atoms(core: Core): string[] {
  core.scene.layout();
  return core.scene.atoms();
}
