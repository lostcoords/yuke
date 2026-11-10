/** The code of the public module `yuke:transcript`. Its declaration is `types/transcript.d.ts`, and the check at the end compares the two. */

import type { EventsPage, Frozen, ViewEvent } from "yuke:plugins";
import type {
  Answer,
  DisplayBlock,
  Input,
  InputId,
  InteractionId,
  SessionSettings,
  SessionState,
  SessionUpdate,
  StoredEvent,
  ToolCall,
  ToolHints,
  Usage,
} from "yuke:protocol";
import type { Entry, Interaction, TurnFailure } from "yuke:transcript";

type Saved = Frozen<StoredEvent>;

interface Draft {
  readonly id: string;
  /** The first public entry of the draft. Several source blocks can share one entry. */
  start: number;
  /** The public entry key of each source block. */
  readonly keys: Map<number, string>;
  /** The source texts of each reasoning run, in block-start order. */
  readonly reasoning: Map<string, Map<number, string>>;
  /** The reasoning run of the last block that started, until a different block kind starts. */
  tail: string | undefined;
}

/** The hints of a call whose tool gave none, or before the host handles it. */
const NO_HINTS: Frozen<ToolHints> = Object.freeze({ title: null, subject: null, preview: "head" });

/** The display of a result without one. One object, so an entry keeps its object across a re-fold. */
const NO_DISPLAY: Frozen<DisplayBlock[]> = Object.freeze([]);

/** The fields of a tool entry before the host handles the call. */
const UNHANDLED = {
  hints: NO_HINTS,
  folder: undefined,
  startedAt: undefined,
  durationMs: undefined,
  output: "",
  result: undefined,
  display: NO_DISPLAY,
} as const;

/** The tool that `call` runs: the bridge call `tool_call` runs the deferred tool that its arguments name. */
function called(call: Frozen<ToolCall>): { name: string; arguments: string } {
  if (call.name === "tool_call") {
    try {
      const inner: unknown = JSON.parse(call.arguments);
      if (typeof inner === "object" && inner !== null && "name" in inner && typeof inner.name === "string") {
        return { name: inner.name, arguments: JSON.stringify("arguments" in inner ? inner.arguments : {}) };
      }
    } catch {
      // The engine refuses such a call, so the entry shows it as the model wrote it.
    }
  }
  return { name: call.name, arguments: call.arguments };
}

export class Transcript {
  readonly entries: Entry[] = [];
  readonly pending = new Map<InputId, Frozen<Input>>();
  readonly questions = new Map<InteractionId, Interaction>();
  #state: SessionState = "idle";
  #settings: Frozen<SessionSettings> | undefined;
  #status: TurnFailure | undefined;
  #usage: Frozen<Usage> | undefined;
  #gap: EventsPage | undefined;
  /** The saved events, by number. */
  #saved: Saved[] = [];
  /** The position of each entry, by key. */
  readonly #index = new Map<string, number>();
  /** The open draft. Its public entries end the list. */
  #draft: Draft | undefined;
  /** The keys of the calls of the last answer that wait for their saved result, in call order. */
  #calls: string[] = [];
  /** The last saved answer since the last end. A turn saves its end in a commit of its own. */
  #turnAnswer: Answer | undefined;
  /** During a re-fold, the entries before it by key, so an entry that did not change keeps its object. */
  #previous: Map<string, Entry> | undefined;

  get state(): SessionState {
    return this.#state;
  }

  get settings(): Frozen<SessionSettings> | undefined {
    return this.#settings;
  }

  get failure(): TurnFailure | undefined {
    return this.#status;
  }

  get usage(): Frozen<Usage> | undefined {
    return this.#usage;
  }

  get first(): number | undefined {
    return this.#saved[0]?.seq;
  }

  get gap(): EventsPage | undefined {
    return this.#gap;
  }

  apply(event: ViewEvent): void {
    if ("update" in event) {
      this.#update(event.update);
      return;
    }
    this.entries.length = 0;
    this.pending.clear();
    this.questions.clear();
    this.#state = "idle";
    this.#settings = event.snapshot.settings;
    this.#status = undefined;
    this.#usage = undefined;
    this.#gap = undefined;
    this.#saved = [];
    this.#index.clear();
    this.#draft = undefined;
    this.#calls = [];
    this.#turnAnswer = undefined;
    for (const update of event.snapshot.updates) this.#update(update);
  }

  insert(events: readonly Saved[]): void {
    const held = new Set(this.#saved.map((event) => event.seq));
    const added = events.filter((event) => !held.has(event.seq));
    if (added.length === 0) return;
    // A commit of a gap can consume an input that waits.
    for (const event of added)
      if (event.sessionUpdate === "commit") for (const input of event.consumed) this.pending.delete(input.id);
    this.#saved = [...this.#saved, ...added].sort((a, b) => a.seq - b.seq);
    this.#gap = undefined;
    for (const [index, event] of this.#saved.entries()) {
      const before = this.#saved[index - 1];
      if (before !== undefined && event.seq > before.seq + 1) {
        this.#gap = { before: event.seq, limit: event.seq - before.seq - 1 };
        break;
      }
    }
    const draft = this.#draft === undefined ? [] : this.entries.slice(this.#draft.start);
    this.#previous = new Map(this.entries.map((entry) => [entry.key, entry]));
    this.entries.length = 0;
    this.#index.clear();
    this.#calls = [];
    this.#turnAnswer = undefined;
    for (const event of this.#saved) this.#fold(event);
    this.#previous = undefined;
    if (this.#draft !== undefined) this.#draft.start = this.entries.length;
    for (const entry of draft) this.#index.set(entry.key, this.entries.push(entry) - 1);
  }

  #update(update: Frozen<SessionUpdate>): void {
    if ("seq" in update) {
      const last = this.#saved.at(-1)?.seq;
      if (last !== undefined && update.seq <= last) return;
      if (last !== undefined && update.seq > last + 1) {
        this.#gap ??= { before: update.seq, limit: update.seq - last - 1 };
      }
      this.#saved.push(update);
      if (update.sessionUpdate === "settings") {
        this.#settings = { model: update.model, settings: update.settings, cwd: update.cwd };
        return;
      }
      for (const input of update.consumed) this.pending.delete(input.id);
      if (update.commit.end !== null) this.#status = undefined;
      this.#dropDraft();
      this.#fold(update);
      return;
    }
    switch (update.sessionUpdate) {
      case "state":
        this.#state = update.state;
        break;
      case "input_accepted":
        this.pending.set(update.inputId, update.input);
        break;
      case "input_removed":
        this.pending.delete(update.inputId);
        break;
      case "interaction_requested":
        this.questions.set(update.interactionId, { source: update.source, request: update.request });
        break;
      case "interaction_closed":
        this.questions.delete(update.interactionId);
        break;
      case "retry_scheduled":
        this.#status = { kind: "retry_scheduled", afterMs: update.afterMs, error: update.error };
        break;
      case "round_failed":
        this.#status = { kind: "round_failed", error: update.error };
        break;
      case "turn_unconfirmed":
        this.#dropDraft();
        for (const key of this.#calls) {
          const entry = this.#at(key);
          if (entry?.kind === "tool")
            this.#set({
              ...entry,
              status: "waiting",
              startedAt: undefined,
              durationMs: undefined,
              output: "",
              result: undefined,
              display: NO_DISPLAY,
            });
        }
        break;
      case "draft_started":
        this.#dropDraft();
        this.#draft = {
          id: update.draftId,
          start: this.entries.length,
          keys: new Map(),
          reasoning: new Map(),
          tail: undefined,
        };
        this.#status = undefined;
        break;
      case "draft_committed":
      case "draft_discarded":
        if (this.#draft?.id === update.draftId) this.#dropDraft();
        break;
      case "model": {
        const draft = this.#draft;
        if (draft?.id !== update.draftId) break;
        const model = update.event;
        if (model.kind === "block_started") {
          const key = `draft:${draft.id}:${model.block}`;
          if (model.content.kind === "reasoning") {
            const group = draft.tail ?? key;
            let parts = draft.reasoning.get(group);
            if (parts === undefined) {
              parts = new Map();
              draft.reasoning.set(group, parts);
              this.#put({ kind: "reasoning", key: group, text: "", draft: true });
            }
            parts.set(model.block, "");
            draft.keys.set(model.block, group);
            draft.tail = group;
          } else {
            draft.tail = undefined;
            draft.keys.set(model.block, key);
            if (model.content.kind === "tool_call") {
              const name = model.content.name;
              this.#put({ kind: "tool", key, name, arguments: "", status: "streaming", ...UNHANDLED });
            } else this.#put({ kind: "text", key, text: "", refusal: model.content.kind === "refusal", draft: true });
          }
          break;
        }
        if (model.kind === "response_completed" || model.kind === "reasoning_section_started") break;
        const entry = this.#at(draft.keys.get(model.block));
        if (entry === undefined) break;
        if (model.kind === "tool_input_delta") {
          if (entry.kind === "tool") this.#set({ ...entry, arguments: entry.arguments + model.text });
        } else if (model.kind === "block_stopped") {
          if (entry.kind === "tool" && model.call !== null)
            this.#set({ ...entry, ...called(model.call), status: "waiting" });
        } else if (entry.kind === "reasoning") {
          // A later block can start before an earlier block sends its last delta.
          const parts = draft.reasoning.get(entry.key) as Map<number, string>;
          parts.set(model.block, (parts.get(model.block) as string) + model.text);
          const text = [...parts.values()].filter((part) => part.trim() !== "").join("\n\n");
          if (text !== entry.text) this.#set({ ...entry, text });
        } else if (entry.kind === "text") {
          this.#set({ ...entry, text: entry.text + model.text });
        }
        break;
      }
      case "tool_started":
      case "tool_output":
      case "tool_finished": {
        const entry = this.#at(`${update.execution.eventNumber}:${update.execution.blockIndex}`);
        if (entry?.kind !== "tool" || entry.status === "done") break;
        if (update.sessionUpdate === "tool_started") this.#set({ ...entry, status: "running", startedAt: Date.now() });
        else if (update.sessionUpdate === "tool_output") this.#set({ ...entry, output: entry.output + update.text });
        else {
          const display = update.display.length === 0 ? NO_DISPLAY : update.display;
          const durationMs = update.durationMs ?? undefined;
          this.#set({ ...entry, status: "done", startedAt: undefined, durationMs, result: update.result, display });
        }
        break;
      }
    }
  }

  /** Add the entries of the saved event `event`. The snapshot and the live settings events give the settings. */
  #fold(event: Saved): void {
    if (event.sessionUpdate === "settings") return;
    const commit = event.commit;
    // A replaced context makes the counts of the earlier answer stale, until the next answer.
    if (commit.replaced !== null) this.#usage = undefined;
    if (commit.answer !== null) {
      this.#usage = commit.answer.usage;
      this.#turnAnswer = commit.answer;
    }
    if (commit.replaced !== null) this.#put({ kind: "compaction", key: `${event.seq}:replaced` });
    let offset = 0;
    for (const input of event.consumed) {
      this.#put({
        kind: "input",
        key: `${event.seq}:${offset}`,
        inputId: input.id,
        source: input.source,
        inputKind: input.kind,
        content: input.displayContent ?? commit.blocks.slice(offset, offset + input.blockCount),
      });
      offset += input.blockCount;
    }
    const refusal = commit.answer?.finishReason === "refusal";
    let answer = false;
    let reasoning: { key: string; parts: string[] } | undefined;
    const flushReasoning = (): void => {
      if (reasoning === undefined) return;
      const text = reasoning.parts.join("\n\n");
      if (text !== "") this.#put({ kind: "reasoning", key: reasoning.key, text, draft: false });
      reasoning = undefined;
    };
    for (const [index, block] of commit.blocks.entries()) {
      if (index < offset) continue;
      const key = `${event.seq}:${index}`;
      if ("reasoning" in block) {
        reasoning ??= { key, parts: [] };
        if (block.reasoning.text.trim() !== "") reasoning.parts.push(block.reasoning.text);
        continue;
      }
      flushReasoning();
      if ("assistant_text" in block)
        this.#put({ kind: "text", key, text: block.assistant_text.text, refusal, draft: false });
      else if ("tool_call" in block) {
        if (!answer) this.#calls = [];
        answer = true;
        this.#calls.push(key);
        const shown = commit.display?.calls.find((call) => call.blockIndex === index);
        this.#put({
          kind: "tool",
          key,
          ...called(block.tool_call),
          status: "waiting",
          ...UNHANDLED,
          ...(shown === undefined ? {} : { hints: shown.hints, folder: shown.folder ?? undefined }),
        });
      } else if ("tool_result" in block) {
        // The results come in the order of the calls. A result whose call is on an older page waits for that page.
        const entry = this.#at(this.#calls.shift());
        const shown = commit.display?.results.find((result) => result.blockIndex === index);
        const display = shown?.blocks ?? NO_DISPLAY;
        if (entry?.kind === "tool") {
          const durationMs = shown?.durationMs ?? undefined;
          const result = block.tool_result;
          this.#set({ ...entry, status: "done", startedAt: undefined, durationMs, output: "", result, display });
        }
      }
    }
    flushReasoning();
    if (commit.end !== null) {
      this.#put({ kind: "end", key: `${event.seq}:end`, end: commit.end, answer: this.#turnAnswer });
      this.#turnAnswer = undefined;
    }
  }

  #at(key: string | undefined): Entry | undefined {
    const position = key === undefined ? undefined : this.#index.get(key);
    return position === undefined ? undefined : this.entries[position];
  }

  /** Add `entry` at the end. */
  #put(entry: Entry): void {
    this.#index.set(entry.key, this.entries.push(this.#kept(entry)) - 1);
  }

  /** Put `entry` in the place of the entry with its key. */
  #set(entry: Entry): void {
    const position = this.#index.get(entry.key);
    if (position !== undefined) this.entries[position] = this.#kept(entry);
  }

  /**
   * The object for `entry`. During a re-fold, the old entry with the same key keeps its object when its fields still
   * hold. Only its own saved event gives an entry, except the result of a tool. A waiting tool keeps its live state.
   */
  #kept(entry: Entry): Entry {
    const previous = this.#previous?.get(entry.key);
    if (entry.kind === "reasoning" && previous?.kind === "reasoning")
      return previous.text === entry.text && previous.draft === entry.draft ? previous : entry;
    // An older page can bring the answer of an end.
    if (entry.kind === "end" && previous?.kind === "end" && previous.answer !== entry.answer) return entry;
    if (previous === undefined || entry.kind !== "tool" || entry.status === "waiting") return previous ?? entry;
    // One saved event gives a result object, its display, and its duration, so the result stands for all three.
    const same =
      previous.kind === "tool" &&
      previous.result === entry.result &&
      previous.hints === entry.hints &&
      previous.output === "";
    return same ? previous : entry;
  }

  #dropDraft(): void {
    const draft = this.#draft;
    if (draft === undefined) return;
    for (const entry of this.entries.slice(draft.start)) this.#index.delete(entry.key);
    this.entries.length = draft.start;
    this.#draft = undefined;
  }
}

// The check against `types/transcript.d.ts` keeps this code and the declarations of the authors in step.
const declared = { Transcript } satisfies typeof import("yuke:transcript");
void declared;
