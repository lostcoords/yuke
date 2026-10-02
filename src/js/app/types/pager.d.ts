export type ItemKey = string | number;

export interface Segment {
  text: string;
  group: string;
  src?: number;
  srcEnd?: number;
  mark?: boolean;
}

export interface TranscriptRow {
  segments?: Segment[] | undefined;
  text?: string | undefined;
  group?: string | undefined;
  /** The source offset of `text` in a row with no `segments`. The row shows its source text as it is, so the source ends at `src + text.length`. */
  src?: number | undefined;
  /** The base highlight group of the complete row. Its background wins, and explicit text fields win every other field. */
  bg?: string | undefined;
  marker?: string | undefined;
  markerGroup?: string | undefined;
  indent?: number | undefined;
  key?: ItemKey | undefined;
  kind?: string | undefined;
  partId?: number | undefined;
  /** The fold header of its part: a click or Enter toggles the part, and the reader lands here. */
  header?: boolean | undefined;
  /** A stop of the part motion, such as the first row of a part. */
  stop?: boolean | undefined;
}

export interface RowSource {
  rowCount: (width: number) => number;
  /**
   * Push the rows from `top` for `height` rows onto `out`. For each row with a selection, in row order, push three numbers onto `sel`: the row index in `out`, then the selected range [from, to) in UTF-16 code units of the row text without its indent.
   * The pager owns both lists and fills them again on each draw.
   */
  rows: (width: number, top: number, height: number, out: TranscriptRow[], sel: number[]) => void;
}
