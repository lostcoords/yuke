// The public module `yuke:transcript`: the fold of the events of a session into the entries of its conversation.

import type {
  Answer,
  Block,
  Commit,
  ConsumedInput,
  DisplayBlock,
  DraftId,
  FinishReason,
  LiveUpdate,
  ModelUpdate,
  SessionSettings,
  SessionUpdate,
  StoredEvent,
  ToolCall,
  ToolHints,
  ToolResult,
} from "yuke:protocol";
import { assert, equal, test } from "yuke:test";
import { type Entry, Transcript } from "yuke:transcript";

const settings: SessionSettings = {
  model: { provider: "p", model: "m" },
  settings: {
    maxOutputTokens: null,
    reasoning: { thinking: null, effort: null },
    temperature: null,
    topP: null,
    toolChoice: "auto",
    outputSchema: null,
  },
  cwd: "/w",
};

function commit(seq: number, fields: Partial<Commit>, consumed: ConsumedInput[] = []): StoredEvent {
  return {
    seq,
    sessionUpdate: "commit",
    commit: { replaced: null, blocks: [], answer: null, end: null, ...fields },
    consumed,
  };
}

function answer(finishReason: FinishReason): Answer {
  const usage = { input: null, output: null, reasoning: null, cacheRead: null, cacheWrite: null };
  return { origin: { model: "m", baseUrl: "https://p" }, usage, finishReason };
}

function model(draftId: DraftId, event: ModelUpdate): LiveUpdate {
  return { sessionUpdate: "model", draftId, event };
}

function position(seq: number, index: number): { eventNumber: number; blockIndex: number } {
  return { eventNumber: seq, blockIndex: index };
}

const call: ToolCall = { callId: "call_0", name: "bash", arguments: '{"command":"cargo test"}' };
const result: ToolResult = { callId: "call_0", content: "1 failed", isError: false };
const userText: Block = { user_text: "fix the test" };
const hints: ToolHints = { title: null, subject: { argument: "command", kind: "text" }, preview: "tail" };
const shown: DisplayBlock[] = [{ kind: "markdown", text: "**1 failed**" }];

/** The updates of one turn in the order of the protocol: it reads a test, runs it, and answers. */
const turn: SessionUpdate[] = [
  { seq: 1, sessionUpdate: "settings", ...settings },
  {
    sessionUpdate: "input_accepted",
    inputId: 1,
    input: { source: { kind: "user" }, kind: "message", content: [userText] },
  },
  { sessionUpdate: "state", state: "running" },
  commit(2, { blocks: [userText] }, [{ id: 1, source: { kind: "user" }, kind: "message", blockCount: 1 }]),
  { sessionUpdate: "draft_started", draftId: "d1" },
  model("d1", { kind: "block_started", block: 0, blockKind: "reasoning" }),
  model("d1", { kind: "reasoning_delta", block: 0, text: "the test " }),
  model("d1", { kind: "reasoning_section_started", block: 0 }),
  model("d1", { kind: "reasoning_delta", block: 0, text: "expects 3" }),
  model("d1", { kind: "block_started", block: 1, blockKind: "text" }),
  model("d1", { kind: "text_delta", block: 1, text: "I run " }),
  model("d1", { kind: "text_delta", block: 1, text: "the tests." }),
  model("d1", { kind: "block_started", block: 2, blockKind: "tool_call" }),
  model("d1", { kind: "tool_input_delta", block: 2, text: '{"command":' }),
  model("d1", { kind: "tool_input_delta", block: 2, text: '"cargo test"}' }),
  model("d1", { kind: "block_stopped", block: 2, call }),
  model("d1", {
    kind: "response_completed",
    finishReason: "tool_calls",
    rawFinishReason: "tool_use",
    usage: answer("tool_calls").usage,
  }),
  commit(3, {
    blocks: [
      { reasoning: { text: "the test expects 3" } },
      { assistant_text: "I run the tests." },
      { tool_call: call },
    ],
    answer: answer("tool_calls"),
    display: { calls: [{ blockIndex: 2, hints, folder: "/w" }], results: [] },
  }),
  { sessionUpdate: "draft_committed", draftId: "d1", eventNumber: 3, blocks: [0, 1, 2] },
  { sessionUpdate: "tool_started", execution: position(3, 2), call },
  { sessionUpdate: "tool_output", execution: position(3, 2), text: "running 1 test\n" },
  { sessionUpdate: "tool_finished", execution: position(3, 2), result, display: shown },
  commit(4, { blocks: [{ tool_result: result }], display: { calls: [], results: [{ blockIndex: 0, blocks: shown }] } }),
  { sessionUpdate: "draft_started", draftId: "d2" },
  model("d2", { kind: "block_started", block: 0, blockKind: "text" }),
  model("d2", { kind: "text_delta", block: 0, text: "Fixed." }),
  model("d2", { kind: "block_stopped", block: 0, call: null }),
  commit(5, { blocks: [{ assistant_text: "Fixed." }], answer: answer("stop") }),
  { sessionUpdate: "draft_committed", draftId: "d2", eventNumber: 5, blocks: [0] },
  commit(6, { end: { outcome: { completed: { finishReason: "stop" } } } }),
  { sessionUpdate: "state", state: "idle" },
];
const saved = turn.filter((update): update is StoredEvent => "seq" in update);

function opened(updates: SessionUpdate[] = []): Transcript {
  const transcript = new Transcript();
  transcript.apply({ snapshot: { settings, updates } });
  return transcript;
}

function fed(transcript: Transcript, updates: readonly SessionUpdate[]): Transcript {
  for (const update of updates) transcript.apply({ update });
  return transcript;
}

function keys(transcript: Transcript): string[] {
  return transcript.entries.map((entry) => entry.key);
}

/** The tool entry at `index`. */
function tool(transcript: Transcript, index: number): Extract<Entry, { kind: "tool" }> {
  const entry = transcript.entries[index];
  assert(entry?.kind === "tool", `the entry ${index} is no tool`);
  return entry;
}

const input: Entry = {
  kind: "input",
  key: "2:0",
  inputId: 1,
  source: { kind: "user" },
  inputKind: "message",
  content: [userText],
};

/** The entries of `turn` after its end. */
const turnEntries: Entry[] = [
  input,
  { kind: "reasoning", key: "3:0", text: "the test expects 3", draft: false },
  { kind: "text", key: "3:1", text: "I run the tests.", refusal: false, draft: false },
  {
    kind: "tool",
    key: "3:2",
    name: "bash",
    arguments: '{"command":"cargo test"}',
    status: "done",
    hints,
    folder: "/w",
    output: "",
    result,
    display: shown,
  },
  { kind: "text", key: "5:0", text: "Fixed.", refusal: false, draft: false },
  { kind: "end", key: "6:end", end: { outcome: { completed: { finishReason: "stop" } } } },
];

test("a live transcript ends equal to a replay of its saved events", () => {
  equal(fed(opened(), turn).entries, turnEntries);
  equal(opened(saved).entries, turnEntries);
});

test("a draft streams its blocks until its saved commit replaces them", () => {
  const transcript = fed(opened(), turn.slice(0, 16));
  equal(transcript.entries, [
    input,
    { kind: "reasoning", key: "draft:d1:0", text: "the test expects 3", draft: true },
    { kind: "text", key: "draft:d1:1", text: "I run the tests.", refusal: false, draft: true },
    {
      kind: "tool",
      key: "draft:d1:2",
      name: "bash",
      arguments: '{"command":"cargo test"}',
      status: "waiting",
      // The host has not handled the call yet, so it has the default hints.
      hints: { title: null, subject: null, preview: "head" },
      folder: undefined,
      output: "",
      result: undefined,
      display: [],
    },
  ]);
  fed(transcript, turn.slice(16, 18));
  equal(keys(transcript), ["2:0", "3:0", "3:1", "3:2"]);
});

test("a tool shows its live output until its saved result", () => {
  const transcript = fed(opened(), turn.slice(0, 20));
  const running = tool(transcript, 3);
  fed(transcript, turn.slice(20, 22));
  const finished = tool(transcript, 3);
  fed(transcript, turn.slice(22, 23));
  equal(
    [running.status, running.output, finished.status, finished.output, tool(transcript, 3).output],
    ["running", "", "done", "running 1 test\n", ""],
  );
});

// Some providers start the call ids of each answer again, so only the saved position tells two calls apart.
test("tool updates reach their call by position when call ids repeat", () => {
  const read: ToolCall = { callId: "call_0", name: "read", arguments: "{}" };
  const transcript = fed(opened(saved.slice(0, 3)), [
    commit(4, { blocks: [{ tool_result: result }] }),
    commit(5, { blocks: [{ tool_call: read }], answer: answer("tool_calls") }),
    { sessionUpdate: "tool_started", execution: position(5, 0), call: read },
    { sessionUpdate: "tool_output", execution: position(5, 0), text: "lib.rs" },
  ]);
  const tools = transcript.entries.filter((entry) => entry.kind === "tool");
  equal(
    tools.map((entry) => [entry.key, entry.name, entry.status, entry.output, entry.result?.content]),
    [
      ["3:2", "bash", "done", "", "1 failed"],
      ["5:0", "read", "running", "lib.rs", undefined],
    ],
  );
});

// An answer cut by its length saves an error result per call in the same commit. A repair commit saves the results of
// the calls that an unconfirmed turn left open.
test("saved results pair with the calls of their answer in the same or a later commit", () => {
  const error = (content: string): Block => ({ tool_result: { callId: "call_0", content, isError: true } });
  const transcript = opened([
    commit(1, {
      blocks: [{ tool_call: call }, { tool_call: call }, error("cut 1"), error("cut 2")],
      answer: answer("length"),
    }),
    commit(2, { blocks: [{ tool_call: call }], answer: answer("tool_calls") }),
    commit(3, { blocks: [error("the turn stopped")], end: { failed: "the turn stopped before it saved its end" } }),
  ]);
  const tools = transcript.entries.filter((entry) => entry.kind === "tool");
  equal(
    tools.map((entry) => [entry.key, entry.status, entry.result?.content]),
    [
      ["1:0", "done", "cut 1"],
      ["1:1", "done", "cut 2"],
      ["2:0", "done", "the turn stopped"],
    ],
  );
});

test("a page that starts mid-turn pairs its results after the older page", () => {
  const transcript = opened(saved.slice(3));
  equal([transcript.first, keys(transcript)], [4, ["5:0", "6:end"]]);
  const later = transcript.entries[0];
  transcript.insert(saved.slice(0, 3));
  equal(transcript.first, 1);
  equal(transcript.entries, turnEntries);
  assert(transcript.entries[4] === later, "an unchanged entry keeps its object");
  const full = opened(saved.slice(1));
  const finished = full.entries[3];
  full.insert(saved.slice(0, 1));
  assert(full.entries[3] === finished, "a tool with the same saved result keeps its object");
});

test("a gap names the missing events and insert fills it", () => {
  const transcript = fed(opened(saved.slice(0, 3)), saved.slice(4));
  equal(transcript.gap, { before: 5, limit: 1 });
  transcript.insert(saved.slice(3, 4));
  equal(transcript.gap, undefined);
  equal(transcript.entries, turnEntries);
});

test("a gap fill removes the inputs that its commits consume", () => {
  const accepted = turn[1];
  assert(accepted !== undefined);
  const transcript = fed(opened(saved.slice(0, 1)), [accepted, ...saved.slice(2)]);
  equal([...transcript.pending.keys()], [1]);
  transcript.insert(saved.slice(1, 2));
  equal([...transcript.pending.keys()], []);
});

test("a cancel mid-draft keeps only what its commit saved", () => {
  const transcript = fed(opened(), [
    ...turn.slice(0, 11),
    commit(3, { blocks: [{ assistant_text: "I run " }], end: { outcome: "cancelled" } }),
    { sessionUpdate: "draft_discarded", draftId: "d1", reason: "failed" },
  ]);
  equal(transcript.entries, [
    input,
    { kind: "text", key: "3:0", text: "I run ", refusal: false, draft: false },
    { kind: "end", key: "3:end", end: { outcome: "cancelled" } },
  ]);
});

test("a context replacement adds a marker and keeps the entries before it", () => {
  const transcript = fed(opened(saved), [
    commit(7, { replaced: { head: [{ user_text: "<context_summary>…" }], keep: 0 } }),
  ]);
  equal(keys(transcript), ["2:0", "3:0", "3:1", "3:2", "5:0", "6:end", "7:replaced"]);
});

test("a change puts a new object only in the place of its entry", () => {
  const transcript = fed(opened(), turn.slice(0, 11));
  const before = [...transcript.entries];
  fed(transcript, turn.slice(11, 12));
  equal(
    transcript.entries.map((entry, index) => entry === before[index]),
    [true, true, false],
  );
});

test("the updates of a draft that started before the snapshot add nothing", () => {
  const transcript = fed(opened(saved.slice(0, 2)), turn.slice(9, 12));
  equal(keys(transcript), ["2:0"]);
  fed(transcript, turn.slice(17, 18));
  equal(keys(transcript), ["2:0", "3:0", "3:1", "3:2"]);
});

test("an unconfirmed turn drops its draft and the live state of its tools", () => {
  const transcript = fed(opened(), [
    ...turn.slice(0, 21),
    { sessionUpdate: "draft_started", draftId: "d2" },
    model("d2", { kind: "block_started", block: 0, blockKind: "text" }),
    { sessionUpdate: "turn_unconfirmed" },
  ]);
  equal(keys(transcript), ["2:0", "3:0", "3:1", "3:2"]);
  equal([tool(transcript, 3).status, tool(transcript, 3).output], ["waiting", ""]);
});

test("the inputs, questions, status, and settings follow their updates", () => {
  const transcript = opened();
  const facts = () => [
    transcript.state,
    [...transcript.pending.keys()],
    [...transcript.questions.keys()],
    transcript.status,
    transcript.settings?.model.model,
  ];
  fed(transcript, turn.slice(0, 3));
  fed(transcript, [
    {
      sessionUpdate: "interaction_requested",
      interactionId: 7,
      source: "ask",
      request: { kind: "confirm", title: "t", message: "m" },
    },
    { sessionUpdate: "retry_scheduled", afterMs: 3000, error: "overloaded" },
  ]);
  equal(facts(), ["running", [1], [7], { kind: "retry_scheduled", afterMs: 3000, error: "overloaded" }, "m"]);
  fed(transcript, [...turn.slice(3, 5), { sessionUpdate: "interaction_closed", interactionId: 7 }]);
  equal(facts(), ["running", [], [], undefined, "m"]);
  fed(transcript, [{ seq: 3, sessionUpdate: "settings", ...settings, model: { provider: "p", model: "n" } }]);
  equal(facts(), ["running", [], [], undefined, "n"]);
  // The snapshot and the live events give the settings. An older page holds older settings.
  const paged = opened([{ seq: 7, sessionUpdate: "settings", ...settings, model: { provider: "p", model: "n" } }]);
  paged.insert(saved);
  equal(paged.settings?.model.model, "n");
});

test("a deferred tool shows the tool that its bridge call names", () => {
  const bridge: ToolCall = { callId: "c", name: "tool_call", arguments: '{"name":"grep","arguments":{"pattern":"x"}}' };
  const transcript = opened([commit(1, { blocks: [{ tool_call: bridge }], answer: answer("tool_calls") })]);
  equal([tool(transcript, 0).name, tool(transcript, 0).arguments], ["grep", '{"pattern":"x"}']);
});

test("usage is the token counts of the last saved answer, and a replaced context or a snapshot clears it", () => {
  const counts = (input: number) => ({ input, output: 10, reasoning: null, cacheRead: null, cacheWrite: null });
  const withUsage = (input: number): Answer => ({ ...answer("stop"), usage: counts(input) });
  const transcript = new Transcript();
  transcript.apply({ snapshot: { settings, updates: [commit(2, { answer: withUsage(100) })] } });
  const first = transcript.usage?.input;
  transcript.apply({ update: commit(3, { answer: withUsage(200) }) });
  transcript.apply({ update: commit(4, { blocks: [userText] }) });
  const last = transcript.usage?.input;
  transcript.apply({ update: commit(5, { replaced: { head: [userText], keep: 0 } }) });
  const compacted = transcript.usage;
  transcript.apply({ update: commit(6, { answer: withUsage(300) }) });
  const next = transcript.usage?.input;
  transcript.apply({ snapshot: { settings, updates: [] } });
  equal([first, last, compacted, next, transcript.usage], [100, 200, undefined, 300, undefined]);
});
