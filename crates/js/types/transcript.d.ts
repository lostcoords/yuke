// The declaration of the public module `yuke:transcript`.

/**
 * The conversation of one session as data, for a chat view or any other frontend. Give each event of `sessions.open`
 * to `apply`. The saved form of a block replaces its streamed form, so a live transcript and a reloaded one end equal.
 *
 * ```ts
 * const transcript = new Transcript();
 * const handle = await sessions.open(id, { tail: 200, event: (event) => transcript.apply(event) });
 * ```
 */
declare module "yuke:transcript" {
  import type { EventsPage, Frozen, ViewEvent } from "yuke:plugins";
  import type {
    Block,
    DisplayBlock,
    EventNumber,
    Input,
    InputId,
    InputKind,
    InputSource,
    InteractionId,
    InteractionRequest,
    SessionSettings,
    SessionState,
    StoredEvent,
    ToolHints,
    ToolResult,
    TurnEnd,
  } from "yuke:protocol";

  /** A message of the user or a notification of a plugin, from the commit that consumed it. */
  export type InputEntry = Frozen<{
    kind: "input";
    key: string;
    inputId: InputId;
    source: InputSource;
    inputKind: InputKind;
    /** What the user saw. */
    content: Block[];
  }>;

  /** Text of the model. `draft` is true while it streams. */
  export type TextEntry = Frozen<{ kind: "text"; key: string; text: string; refusal: boolean; draft: boolean }>;

  /** Reasoning of the model. `draft` is true while it streams. */
  export type ReasoningEntry = Frozen<{ kind: "reasoning"; key: string; text: string; draft: boolean }>;

  /**
   * A tool call of the model.
   * - `streaming`: the model writes the call. `name` is empty until the call is complete.
   * - `waiting`: the call is complete. The transcript knows no run of it yet. A snapshot has no runs, so a call that
   *   runs since before the snapshot shows as `waiting`.
   * - `running`: the call runs. `output` grows.
   * - `done`: `result` holds the result. The saved result replaces the live result. It also clears `output`.
   *
   * `hints` tell how to show the call. A streamed call has the default hints, and the saved answer gives the hints of
   * its tool before the call starts. `folder` is the folder where the call ran, the start of a relative path of the
   * call. `display` is what to show in place of the result text, and it is empty for a result without one. The model
   * sees neither.
   */
  export type ToolEntry = Frozen<{
    kind: "tool";
    key: string;
    name: string;
    arguments: string;
    status: "streaming" | "waiting" | "running" | "done";
    hints: ToolHints;
    folder: string | undefined;
    output: string;
    result: ToolResult | undefined;
    display: DisplayBlock[];
  }>;

  /** The model context was replaced here, for example by a compaction. The entries before it stay. */
  export type CompactionEntry = Frozen<{ kind: "compaction"; key: string }>;

  /** The end of a turn. */
  export type EndEntry = Frozen<{ kind: "end"; key: string; end: TurnEnd }>;

  /** One entry of the conversation. `key` is unique in the transcript and has no meaning beyond that. */
  export type Entry = InputEntry | TextEntry | ReasoningEntry | ToolEntry | CompactionEntry | EndEntry;

  /** An open question to the user. */
  export type Question = Frozen<{ source: string; request: InteractionRequest }>;

  /** A failure of the running turn that is not its end. */
  export type Status = Frozen<
    { kind: "retry_scheduled"; afterMs: number; error: string } | { kind: "round_failed"; error: string }
  >;

  /**
   * The fold of the events of one session. A change never alters an entry: it puts a new entry object in its place.
   * A view can cache its render of an entry by the object.
   */
  export class Transcript {
    /** An empty transcript: no entries, `idle`, and no settings until the first snapshot. */
    constructor();
    /** The entries, oldest first. The array stays the same. A changed entry gets a new object in its place. */
    readonly entries: readonly Entry[];
    /** The inputs that wait for a turn, by id. */
    readonly pending: ReadonlyMap<InputId, Frozen<Input>>;
    /** The open questions, by id. */
    readonly questions: ReadonlyMap<InteractionId, Question>;
    get state(): SessionState;
    get settings(): Frozen<SessionSettings> | undefined;
    /** The last failure of the running turn, until its next draft or its end. */
    get status(): Status | undefined;
    /** The first saved event that the transcript holds: the `before` of the next older page. */
    get first(): EventNumber | undefined;
    /** Saved events that are missing between the held ones. Give the result of `sessions.events` to `insert`. */
    get gap(): EventsPage | undefined;
    /** Add one event. A snapshot starts the transcript again. */
    apply(event: ViewEvent): void;
    /** Add saved events that did not come live: an older page, or the events of a gap. */
    insert(events: readonly Frozen<StoredEvent>[]): void;
  }
}
