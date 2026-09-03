declare module "yuke:diff" {
  interface DiffHunk {
    /** The start values are 1-based. A side with no line has start 0 and count 0. */
    oldStart: number;
    oldLines: number;
    newStart: number;
    newLines: number;
    /** Unified-diff body lines, each with a leading space, `-`, or `+`. */
    lines: string[];
  }

  interface DiffFile {
    path: string;
    hunks: DiffHunk[];
  }

  /**
   * Compares two texts. `path` only labels the result. An equal pair, a side above the size cap,
   * and a change too large to describe all answer no hunk.
   */
  export function diff(path: string, before: string, after: string): Promise<DiffFile>;
}
