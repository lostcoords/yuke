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
  bg?: string | undefined;
  marker?: string | null | undefined;
  markerGroup?: string | undefined;
  indent?: number | undefined;
  key?: ItemKey | undefined;
  kind?: string | undefined;
  partId?: number | undefined;
  sel?: { from: number; to: number } | undefined;
  selGroup?: string | undefined;
}

export interface RowSource {
  rowCount: (width: number) => number;
  rows: (width: number, top: number, height: number) => TranscriptRow[];
}
