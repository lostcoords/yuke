import type { Document } from "../md.js";
import type { TranscriptRow } from "./pager.js";
import type { MessagePart, PartRead, TextCursor } from "yuke:internal/native/engine";

/** One message in the transcript outline. `source` names the engine source of an input. `error` holds the failure of the message, if any. */
export interface MessageDescriptor {
  id: number;
  type: "user" | "assistant" | "compaction";
  source?: Wire.InputSource;
  skill_name?: string;
  error?: Wire.MessageError;
}

/** A place in the transcript: message `id`, `row` counts the rendered rows of that message from 0, and `col` indexes the row text. */
export interface Position {
  id: number;
  row: number;
  col: number;
}

/** The two ends of a selection. `anchor` stays where the selection started and `cursor` moves; either end can come first. */
export interface Selection {
  anchor: Position;
  cursor: Position;
}

/** The part under a position: message `id`, part `partId`, and the row `kind`, such as "tool-header" or "reasoning-body". */
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
}

export interface PartCache {
  w: number;
  expanded: boolean;
  live: boolean;
  shape: number;
  rows: TranscriptRow[];
  source: string;
  /** `part` is the part object `doc` holds the text of; `kept` counts the leading rows the last build left in place. */
  text: { doc: Document; part: Wire.AssistantPart | null; width: number; ends: number[]; kept: number } | null;
}

export interface PartState {
  list: Wire.AssistantPart[] | null;
  rows: Map<string, PartCache>;
}

/** Read every part of message `id`. */
export type PartsOf = (id: number) => readonly MessagePart[];
/** Read one part of message `id`, or null when it is gone. */
export type PartOf = (id: number, partId: number, cursor?: TextCursor) => PartRead | null;
/** Read one page of the cut field `field` of a part from `offset`. `next` is the offset of the next page, or null after the last page. */
export type PartTextPage = (id: number, partId: number, field: string, offset?: number, limit?: number) => { text: string; next: number | null };

/** The readers of a transcript. Without `partsOf` the transcript shows no parts. `onSelect` receives the text of each finished mouse selection. */
export interface TranscriptOptions {
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

/** The header words of a tool call: `verb` first, then `subject`. `category` picks the style group, as in `Presenter`. */
export interface ToolLabel {
  verb: string;
  subject: string;
  category: string;
}

/** Names one tool call in its transcript header. It must not walk the tool output and must not scan a whole text, because it runs when the row builds. */
export interface Presenter {
  /** The style group of the header. "read", "write", "run", and "agent" use TxToolRead, TxToolWrite, TxToolRun, and TxToolAgent; any other value uses TxToolName. */
  category: string;
  /**
   * Answer the header words: `verb` first, then `subject`. A throw shows the tool name with no subject.
   * @param args - The parsed JSON arguments, or `{}` when they do not parse.
   * @param raw - The argument text before the parse.
   */
  present(args: Record<string, unknown>, raw: string, part: Extract<Wire.AssistantPart, { type: "tool" }>): { verb: string; subject: string };
}

/** The label above an input from each engine source; a missing source shows its type name. */
export type SourceLabels = { [K in Wire.InputSource["type"]]?: (source: Extract<Wire.InputSource, { type: K }>) => string };
