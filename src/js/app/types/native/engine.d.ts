// The `yuke:internal/native/engine` surface: the JavaScript seam onto the one in-process engine.
declare module "yuke:internal/native/engine" {
  /** One session's outline: the committed message ids and roles, plus the live draft. */
  export type SessionOutline = {
    messages: { id: number; type: "user" | "assistant" | "compaction"; source?: Wire.InputSource; skill_name?: string; error?: Wire.MessageError }[];
    active: { id: number; type: "assistant" } | null;
  };

  /** The digest keeps each auth event whole, because a login outcome carries a message a fact name cannot. */
  export type AuthNote = { method: "auth.login_finished"; params: Wire.AuthLoginFinishedData };

  /** A drain names transcript work and broadcast facts; index overflow requires a full refresh for dropped session facts. */
  export type EngineEvent =
    | { type: "activity" }
    | { type: "index"; overflow: boolean; facts: Wire.BroadcastName[]; auth?: AuthNote[]; notices?: Wire.Notice[] }
    | { type: "session"; session: string; kind: "quiet" | "active" | "reload" | "gone"; id?: number; part?: number; facts: Wire.BroadcastName[] };

  /** One page of text. `next` is the offset to ask for, or null at the end. */
  export type TextPage = { text: string; next: number | null; bytes: number };

  /** One value the projection cut: `field` is the address `partText` takes, `bytes` or `total` is the whole size, and `next` is where a reader resumes. */
  export type ViewCut = { field: string; bytes?: number; total?: number; next?: number };

  /** One part of a message. A user content part has no wire id, so its position is the id. */
  export type MessagePart = Wire.AssistantPart | (Wire.ContentPart & { id: number });

  /** One part as the read surface returns it: the wire part plus every value the projection cut. */
  export type ViewPart = MessagePart & { cut?: readonly ViewCut[]; text_generation?: number; text_bytes?: number; text_offset?: number };

  /** The QuickJS allocation counters exclude unused memory in the backing allocator. */
  export type MemoryUsage = {
    heap: number; limit: number;
    strings: number; stringCount: number;
    objects: number; objectCount: number;
    properties: number; propertyCount: number;
    shapes: number; arrayCount: number; fastArrayElements: number;
  };

  export type EngineLoad = { runs: number; childRuns: number; continuations: number };

  export const native: {
    /** Every run this process owns, the child runs among them, and the continuations; all zero before engine attach. */
    load(): EngineLoad;
    /** Every fact the engine can publish, so a bus declares them without drift. */
    factNames(): Wire.BroadcastName[];
    /** What the JavaScript runtime holds right now, separate from the process footprint. */
    memoryUsage(): MemoryUsage;
    /** Set the child run concurrency and nesting depth limits. */
    /** An undefined limit keeps the engine value; the answer is the pair from before the call. */
    setAgentLimits(maxConcurrent?: number, maxDepth?: number): [number, number];
    /** Install the one sink. `drain` calls it on the owner, never from an engine task. */
    setEventSink(fn: (ev: EngineEvent) => void): void;
    /** Resolve with the response JSON, or reject with an error that carries the refusal code. */
    request(method: string, params: string): Promise<string>;
    /** Pin a session for one open view. Returns false when the engine cannot open it. */
    sessionOpen(sessionId: string): boolean;
    /** Drop one view's pin. Every open owes exactly one close. */
    sessionClose(sessionId: string): void;
    /** The outline as JSON, or "null" when the session is not open. */
    sessionOutline(sessionId: string): string;
    /** The live `SessionActivity` as JSON, or "null" when the session is not open. */
    sessionActivity(sessionId: string): string;
    /** The parts of one message as JSON. A user part takes its position as its id. */
    sessionParts(sessionId: string, messageId: number): string;
    /** One part as JSON; a draft cursor reads the suffix at a byte offset within the same lifetime. */
    sessionPart(sessionId: string, messageId: number, partId: number, generation?: number, offset?: number): string;
    /** One page of one field of a part, as JSON `TextPage`. `field` is the address a `ViewCut` names. */
    partText(sessionId: string, messageId: number, partId: number, field: string, offset: number, limit: number): string;
  };
}
