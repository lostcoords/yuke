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

/** The part under a position: message `id`, part `partId` (-1 for a whole message), and the row under the position. */
export interface PartHit {
  id: number;
  partId: number;
  row: TranscriptRow;
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
  /** The message source. Null until a read joins the part sources, so a build concatenates no strings. */
  source: string | null;
  partBases: Map<string, number>;
}

export interface PartCache {
  w: number;
  expanded: boolean;
  live: boolean;
  shape: number;
  /** The group header rows that the last build wrote before this part. */
  lead: number;
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

export interface GroupPlan {
  trees: number[] | Float64Array;
  starts: number[] | Float64Array;
  joinAfter: number[] | Uint8Array;
}

export interface GroupEntry {
  part: number;
  message: number;
}

/** The label above an input from each engine source; a missing source shows its type name. */
export type SourceLabels = { [K in Wire.InputSource["type"]]?: (source: Extract<Wire.InputSource, { type: K }>) => string };

/** A tool call part. */
export type ToolPart = Extract<Wire.AssistantPart, { type: "tool" }>;
/** A reasoning part. */
export type ReasoningPart = Extract<Wire.AssistantPart, { type: "reasoning" }>;

/** The words and raw input behind one tool header. A nonempty `input` with each line feed replaced by a space equals `subject`. An empty `input` means no hidden input. */
export interface ToolHeading {
  verb: string;
  subject: string;
  category: string;
  input: string;
}

/**
 * Build the heading of one tool call. `category` names the kind of work, such as "read", "write", "run", or "agent"; a look picks a style from it.
 * It runs when the row builds, so it must not walk the tool output. `args` holds the parsed JSON arguments, or `{}` when they do not parse.
 */
export type ToolHead = (args: Record<string, any>, part: ToolPart) => ToolHeading;

/** The rows of a render and the text they show. The `src` and `srcEnd` of each segment index `source`, so a selection copies the source text. */
export interface Rendered {
  rows: TranscriptRow[];
  source: string;
}

/** The facts of one part render. The core builds a new one for each call. */
export interface PartEnv {
  /** The message that holds the part. */
  messageId: number;
  /** The columns of the rows. A row indent counts inside them. */
  width: number;
  /** True when the part shows open: the choice of the user, else ctrl+o, else the `fold` hook. */
  expanded: boolean;
  /** True while the part is the last reasoning of the streaming draft. */
  live: boolean;
  /** The place of the part in its group, or null outside a group. */
  group: { count: number; first: boolean; last: boolean } | null;
  /** The `tools` of every renderer, merged by tool name. */
  tools: Record<string, ToolHead>;
}

/** The facts of one message, error, or group header render. `expanded` is the fold state of the whole message. */
export interface MessageEnv {
  messageId: number;
  width: number;
  expanded: boolean;
}

/**
 * A transcript renderer. Every member is optional. A hook that answers undefined passes to the renderer below it, so a plugin can own one tool or one message source.
 * The core writes `key` and `partId` on each row a hook answers. A hook runs when the rows build: at a change, a new width, or a fold, never on each frame.
 */
export interface Render {
  /** The rows of one tool or reasoning part. The core builds text parts itself as markdown. */
  part?(part: ToolPart | ReasoningPart, env: PartEnv): Rendered | undefined;
  /** The rows of one user or compaction message. `parts` holds its text and media parts. */
  message?(message: MessageDescriptor, parts: readonly MessagePart[], env: MessageEnv): Rendered | undefined;
  /** The rows under a message that failed. */
  error?(error: Wire.MessageError, env: MessageEnv): Rendered | undefined;
  /** The group of a part. Consecutive parts with one key form a group, and null closes the group. Without this hook, no part groups. */
  groupKey?(part: Wire.AssistantPart): string | null | undefined;
  /** The rows above a group. */
  groupHeader?(group: { key: string | null; count: number }, env: MessageEnv): TranscriptRow[] | undefined;
  /** True to show a part open until the user or ctrl+o folds it. `live` is true for the reasoning that still streams. */
  fold?(part: Wire.AssistantPart, live: boolean): boolean | undefined;
  /** True when `fresh` gives the same rows and the same source as `before`, so a streamed delta skips the rebuild. A folded part keeps its whole source, so a hidden output change is not the same. */
  sameVisible?(before: Wire.AssistantPart, fresh: Wire.AssistantPart, expanded: boolean): boolean | undefined;
  /** Act on a click or an Enter on a part. Answer where the reader lands, or null. Without an answer, a part with a header row toggles its fold. */
  activate?(hit: PartHit, transcript: import("../transcript.js").Transcript): Position | null | undefined;
  /** Header words by tool name, for any look. */
  tools?: Record<string, ToolHead>;
  /** Labels by input source type. */
  sources?: SourceLabels;
  /** The indent of the text rows of an assistant message. */
  indent?: number;
  /** The blank rows between two parts of one message. */
  gap?: number;
}
