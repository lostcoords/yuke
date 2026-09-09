export interface SourceRun {
  at: number;
  src: number;
  len: number;
}

export type StringList = string[] & { [index: number]: string };
export type NumberList = number[] & { [index: number]: number };
export type FenceMatch = [full: string, indent: string, fence: string, lang: string];
export type FenceCloseMatch = [full: string, indent: string, fence: string];
export type HeadingMatch = [full: string, indent: string, marks: string, spacing: string | undefined, text: string | undefined];
export type QuoteMatch = [full: string, indent: string, spacing: string, text: string];
export type UlItemMatch = [full: string, indent: string, marker: string, spacing: string, text: string];
export type OlItemMatch = [full: string, indent: string, number: string, delimiter: string, spacing: string, text: string];

export interface InlineSource {
  text: string;
  runs: SourceRun[];
}

export interface TableCell {
  text: string;
  runs: SourceRun[];
}

export interface Fence {
  marker: string;
  length: number;
  indent: number;
  lang: string;
}

export interface ListItem {
  indent: number;
  marker: string;
  text: string;
  runs: SourceRun[];
  markAt: number;
  markEnd: number;
}

export interface BlockMeta {
  raw: string;
  at: number;
  end: number;
  open?: boolean;
}

export type CodeBlock = BlockMeta & { kind: "code"; lang: string; lines: StringList; lineAt: NumberList; closed: boolean };
export type HeadingBlock = BlockMeta & { kind: "heading"; level: number; text: string; runs: SourceRun[] };
export type QuoteBlock = BlockMeta & { kind: "quote"; text: string; runs: SourceRun[]; markAt: number; markEnd: number };
export type ListBlock = BlockMeta & { kind: "list"; ordered: boolean; items: ListItem[] };
export type TableBlock = BlockMeta & { kind: "table"; columns: number; rows: TableCell[][]; sepAt: number; sepEnd: number };
export type ParagraphBlock = BlockMeta & { kind: "paragraph"; text: string; runs: SourceRun[] };
export type RuleBlock = BlockMeta & { kind: "hr" };
export type Block = CodeBlock | HeadingBlock | QuoteBlock | ListBlock | TableBlock | ParagraphBlock | RuleBlock;

export interface BlockSummary {
  kind: Block["kind"];
  at: number;
  end: number;
}

export type TextNode = { kind: "text"; text: string; at: number; len: number };
export type StyledNode = { kind: "seg"; text: string; group: string; at: number; len: number };
export interface DelimiterNode {
  kind: "delim";
  text: string;
  at: number;
  len: number;
  marker: string;
  count: number;
  canOpen: boolean;
  canClose: boolean;
  openStrong?: number;
  closeStrong?: number;
  openEm?: number;
  closeEm?: number;
}
export type InlineNode = TextNode | StyledNode | DelimiterNode;
export type InlinePiece = { text: string; group: string; at: number; len: number };
export type Segment = { text: string; group: string; src?: number; srcEnd?: number; mark?: boolean };
export type LinearSegment = { src: number; srcEnd: number; text: string; group: string };
export type Row = { segments: Segment[] };
export type BreakPiece = { segments: Segment[]; w: number };
export type Word = { pieces: Segment[]; w: number; spaceGroup: string | null };
export type WrapOptions = { firstPrefix?: Segment; contPrefix?: Segment; emptyGroup?: string; limit?: number };
export type CacheEntry = { raw: string; width: number; rows: Row[] };
