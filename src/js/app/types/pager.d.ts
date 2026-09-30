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
  marker?: string | null | undefined;
  markerGroup?: string | undefined;
  indent?: number | undefined;
  key?: ItemKey | undefined;
  kind?: string | undefined;
  partId?: number | undefined;
  /** The fold header of its part: a click or Enter toggles the part, and the reader lands here. */
  header?: boolean | undefined;
  /** A stop of the part motion, such as the first row of a part. */
  stop?: boolean | undefined;
  sel?: { from: number; to: number } | undefined;
  selGroup?: string | undefined;
}

export interface RowSource {
  rowCount: (width: number) => number;
  rows: (width: number, top: number, height: number) => TranscriptRow[];
}
