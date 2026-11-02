import type { Frame } from "yuke:test";

/** The text of each row, without trailing spaces. */
export function rows(frame: Frame): string[] {
  return frame.cells.map((row) =>
    row
      .map((cell) => cell.text)
      .join("")
      .trimEnd(),
  );
}
