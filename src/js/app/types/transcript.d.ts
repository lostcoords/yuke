import type { Document } from "../md.js";
import type { TranscriptRow } from "./pager.js";

export interface MessageDescriptor {
  id: number;
  type: "user" | "assistant" | "compaction";
  source?: Wire.InputSource;
  skill_name?: string;
  error?: { type: string; message: string };
}

export interface Position {
  id: number;
  row: number;
  col: number;
}

export interface Selection {
  anchor: Position;
  cursor: Position;
}

export interface PartHit {
  id: number;
  partId: number;
  kind: string;
}

export interface SelectionAnchors {
  a: { id: number; off: number; was: string; partId?: string };
  b: { id: number; off: number; was: string; partId?: string };
}

export interface SelectionRange {
  start: Position;
  end: Position;
  si: number;
  ei: number;
}

export interface RowCache {
  w: number;
  rows: TranscriptRow[];
  source: string;
  partBases: Map<string, number>;
  doc: Document | undefined;
}

export interface PartCache {
  w: number;
  expanded: boolean;
  live: boolean;
  shape: number;
  rows: TranscriptRow[];
  source: string;
  doc: Document | null;
}

export interface PartState {
  list: Wire.AssistantPart[] | null;
  rows: Map<string, PartCache>;
}

export type PartsOf = (id: number) => readonly Wire.AssistantPart[];
export type PartOf = (id: number, partId: number) => Wire.AssistantPart | null;
export type PartTextPage = (id: number, partId: number, field: string, offset?: number, limit?: number) => { text: string; next: number | null };

export interface CodeBlock {
  id: number;
  lang: string;
  text: string;
}

export interface TranscriptOptions {
  textOf?: ((id: number) => string) | undefined;
  partsOf?: PartsOf | null | undefined;
  partOf?: PartOf | null | undefined;
  partTextPage?: PartTextPage | null | undefined;
  onSelect?: ((text: string) => void) | null | undefined;
}

export interface ActionPlan {
  trees: number[] | Float64Array;
  starts: number[] | Float64Array;
  joinAfter: number[] | Uint8Array;
}

export interface ActionEntry {
  part: number;
  message: number;
}

export interface ToolLabel {
  verb: string;
  subject: string;
  category: string;
}

export interface Presenter {
  category: string;
  present(args: Record<string, any>, raw: string): { verb: string; subject: string };
}
