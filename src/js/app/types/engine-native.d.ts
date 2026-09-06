// The `yuke:engine-native` surface: the JavaScript seam onto the one in-process engine.
declare module "yuke:engine-native" {
  /** One session's outline: the committed message ids and roles, plus the live draft. */
  export type SessionOutline = {
    messages: { id: number; type: "user" | "assistant" | "compaction"; error?: { type: string; message: string } }[];
    active: { id: number; type: "assistant" } | null;
  };

  /** The digest keeps each auth event whole, because a login outcome carries a message a fact name cannot. */
  export type AuthNote =
    | { method: "auth.login_finished"; params: Wire.AuthLoginFinishedData }
    | { method: "auth.changed"; params: Wire.AuthChangedData };

  /** One drain: `kind` names the work the transcript owes, and `facts` names every broadcast it coalesced. */
  export type EngineEvent =
    | { type: "index"; facts: Wire.BroadcastName[]; auth?: AuthNote[] }
    | { type: "session"; session: string; kind: "quiet" | "active" | "reload" | "gone"; id?: number; part?: number; facts: Wire.BroadcastName[] };

  /** One page of text. `next` is the offset to ask for, or null at the end. */
  export type TextPage = { text: string; next: number | null; bytes: number };

  /** One value the projection cut: `field` is the address `partText` takes, `bytes` or `total` is the whole size, and `next` is where a reader resumes. */
  export type ViewCut = { field: string; bytes?: number; total?: number; next?: number };

  /** One part as the read surface returns it: the wire part plus every value the projection cut. */
  export type ViewPart = Wire.AssistantPart & { cut?: readonly ViewCut[] };

  /** The QuickJS allocation counters exclude unused memory in the backing allocator. */
  export type MemoryUsage = {
    heap: number; limit: number;
    strings: number; stringCount: number;
    objects: number; objectCount: number;
    properties: number; propertyCount: number;
    shapes: number; arrayCount: number; fastArrayElements: number;
  };

  export const native: {
    /** Every fact the engine can publish, so a bus declares them without drift. */
    factNames(): Wire.BroadcastName[];
    /** What the JavaScript runtime holds right now, separate from the process footprint. */
    memoryUsage(): MemoryUsage;
    /** Set or clear the default prompt for new sessions. Null clears it. */
    setDefaultSystemPrompt(prompt: string | null): void;
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
    /** The assistant parts as JSON. Each part carries bounded text plus its real `bytes`. */
    sessionParts(sessionId: string, messageId: number): string;
    /** One part as a one-element JSON array, or `[]` when it is gone. */
    sessionPart(sessionId: string, messageId: number, partId: number): string;
    /** One page of a message's whole text, as JSON `TextPage`. */
    sessionText(sessionId: string, messageId: number, offset: number, limit: number): string;
    /** One page of one field of a part, as JSON `TextPage`. `field` is the address a `ViewCut` names. */
    partText(sessionId: string, messageId: number, partId: number, field: string, offset: number, limit: number): string;
  };
}
