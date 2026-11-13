// The public module `yuke:transcript`: the fold of the events of a session into the entries of its conversation.

import type {
  Answer,
  Block,
  DisplayBlock,
  SessionUpdate,
  StoredEvent,
  ToolCall,
  ToolHints,
  ToolResult,
} from "yuke:protocol";
import { assert, assertEquals, test } from "yuke:test";
import { type Entry, Transcript } from "yuke:transcript";
import { answer, commit, fed, model, opened, settings } from "./transcript-fixtures.ts";

function position(seq: number, index: number): { eventNumber: number; blockIndex: number } {
  return { eventNumber: seq, blockIndex: index };
}

const call: ToolCall = { callId: "call_0", name: "bash", arguments: '{"command":"cargo test"}' };
const result: ToolResult = { callId: "call_0", content: "1 failed", isError: false };
const userText: Block = { kind: "userText", text: "fix the test" };
const hints: ToolHints = { subject: { argument: "command", kind: "text" }, preview: "tail" };
const shown: DisplayBlock[] = [{ kind: "markdown", text: "**1 failed**" }];

/** The updates of one turn in the order of the protocol: it reads a test, runs it, and answers. */
const turn: SessionUpdate[] = [
  { seq: 1, sessionUpdate: "settings", ...settings },
  {
    sessionUpdate: "inputAccepted",
    inputId: 1,
    input: { source: { kind: "user" }, kind: "message", content: [userText] },
  },
  { sessionUpdate: "state", state: "running" },
  commit(2, { blocks: [userText] }, [{ id: 1, source: { kind: "user" }, kind: "message", blockCount: 1 }]),
  { sessionUpdate: "draftStarted", draftId: "d1" },
  model("d1", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
  model("d1", { kind: "reasoningDelta", blockId: 0, text: "the test " }),
  model("d1", { kind: "reasoningSectionStarted", blockId: 0 }),
  model("d1", { kind: "reasoningDelta", blockId: 0, text: "expects 3" }),
  model("d1", { kind: "blockStarted", blockId: 1, content: { kind: "text" } }),
  model("d1", { kind: "textDelta", blockId: 1, text: "I run " }),
  model("d1", { kind: "textDelta", blockId: 1, text: "the tests." }),
  model("d1", { kind: "blockStarted", blockId: 2, content: { kind: "toolCall", name: "bash" } }),
  model("d1", { kind: "toolInputDelta", blockId: 2, text: '{"command":' }),
  model("d1", { kind: "toolInputDelta", blockId: 2, text: '"cargo test"}' }),
  model("d1", { kind: "blockStopped", blockId: 2, call }),
  model("d1", {
    kind: "responseCompleted",
    finishReason: "toolCalls",
    rawFinishReason: "tool_use",
    usage: answer("toolCalls").usage,
  }),
  commit(3, {
    blocks: [
      { kind: "reasoning", text: "the test expects 3" },
      { kind: "assistantText", text: "I run the tests." },
      { kind: "toolCall", ...call },
    ],
    answer: answer("toolCalls"),
    display: { calls: [{ blockIndex: 2, hints, cwd: "/w" }], results: [] },
  }),
  { sessionUpdate: "draftCommitted", draftId: "d1", eventNumber: 3, blocks: [0, 1, 2] },
  { sessionUpdate: "toolStarted", position: position(3, 2), call },
  { sessionUpdate: "toolOutput", position: position(3, 2), text: "running 1 test\n" },
  { sessionUpdate: "toolFinished", position: position(3, 2), result, display: shown, durationMs: 40_000 },
  commit(4, {
    blocks: [{ kind: "toolResult", ...result }],
    display: { calls: [], results: [{ blockIndex: 0, blocks: shown, durationMs: 40_000 }] },
  }),
  { sessionUpdate: "draftStarted", draftId: "d2" },
  model("d2", { kind: "blockStarted", blockId: 0, content: { kind: "text" } }),
  model("d2", { kind: "textDelta", blockId: 0, text: "Fixed." }),
  model("d2", { kind: "blockStopped", blockId: 0 }),
  commit(5, { blocks: [{ kind: "assistantText", text: "Fixed." }], answer: answer("stop") }),
  { sessionUpdate: "draftCommitted", draftId: "d2", eventNumber: 5, blocks: [0] },
  commit(6, { end: { kind: "completed", finishReason: "stop" } }),
  { sessionUpdate: "state", state: "idle" },
];
const saved = turn.filter((update): update is StoredEvent => "seq" in update);

function keys(transcript: Transcript): string[] {
  return transcript.entries.map((entry) => entry.id);
}

/** The tool entry at `index`. */
function tool(transcript: Transcript, index: number): Extract<Entry, { kind: "tool" }> {
  const entry = transcript.entries[index];
  assert(entry?.kind === "tool", `the entry ${index} is no tool`);
  return entry;
}

const input: Entry = {
  kind: "input",
  id: "2:0",
  inputId: 1,
  source: { kind: "user" },
  inputKind: "message",
  content: [userText],
};

/** The entries of `turn` after its end. */
const turnEntries: Entry[] = [
  input,
  { kind: "reasoning", id: "3:0", text: "the test expects 3", draft: false },
  { kind: "text", id: "3:1", text: "I run the tests.", refusal: false, draft: false },
  {
    kind: "tool",
    id: "3:2",
    name: "bash",
    arguments: '{"command":"cargo test"}',
    status: "done",
    hints,
    cwd: "/w",
    startedAt: undefined,
    durationMs: 40_000,
    output: "",
    result,
    display: shown,
  },
  { kind: "text", id: "5:0", text: "Fixed.", refusal: false, draft: false },
  {
    kind: "end",
    id: "6:end",
    end: { kind: "completed", finishReason: "stop" },
    answer: answer("stop"),
  },
];

test("a live transcript ends equal to a replay of its saved events", () => {
  assertEquals(fed(opened(), turn).entries, turnEntries);
  assertEquals(opened(saved).entries, turnEntries);
});

test("a draft streams its blocks until its saved commit replaces them", () => {
  const transcript = fed(opened(), turn.slice(0, 16));
  assertEquals(transcript.entries, [
    input,
    { kind: "reasoning", id: "draft:d1:0", text: "the test expects 3", draft: true },
    { kind: "text", id: "draft:d1:1", text: "I run the tests.", refusal: false, draft: true },
    {
      kind: "tool",
      id: "draft:d1:2",
      name: "bash",
      arguments: '{"command":"cargo test"}',
      status: "waiting",
      // The host has not handled the call yet, so it has the default hints.
      hints: { preview: "head" },
      cwd: undefined,
      startedAt: undefined,
      durationMs: undefined,
      output: "",
      result: undefined,
      display: [],
    },
  ]);
  fed(transcript, turn.slice(16, 18));
  assertEquals(keys(transcript), ["2:0", "3:0", "3:1", "3:2"]);
});

test("a tool shows its live output until its saved result", () => {
  const transcript = fed(opened(), turn.slice(0, 20));
  const running = tool(transcript, 3);
  fed(transcript, turn.slice(20, 22));
  const finished = tool(transcript, 3);
  fed(transcript, turn.slice(22, 23));
  assertEquals(
    [running.status, running.output, finished.status, finished.output, tool(transcript, 3).output],
    ["running", "", "done", "running 1 test\n", ""],
  );
});

// Some providers start the call ids of each answer again, so only the saved position tells two calls apart.
test("tool updates reach their call by position when call ids repeat", () => {
  const read: ToolCall = { callId: "call_0", name: "read", arguments: "{}" };
  const transcript = fed(opened(saved.slice(0, 3)), [
    commit(4, { blocks: [{ kind: "toolResult", ...result }] }),
    commit(5, { blocks: [{ kind: "toolCall", ...read }], answer: answer("toolCalls") }),
    { sessionUpdate: "toolStarted", position: position(5, 0), call: read },
    { sessionUpdate: "toolOutput", position: position(5, 0), text: "lib.rs" },
  ]);
  const tools = transcript.entries.filter((entry) => entry.kind === "tool");
  assertEquals(
    tools.map((entry) => [entry.id, entry.name, entry.status, entry.output, entry.result?.content]),
    [
      ["3:2", "bash", "done", "", "1 failed"],
      ["5:0", "read", "running", "lib.rs", undefined],
    ],
  );
});

// An answer cut by its length saves an error result per call in the same commit. A repair commit saves the results of
// the calls that an unconfirmed turn left open.
test("saved results pair with the calls of their answer in the same or a later commit", () => {
  const error = (content: string): Block => ({ kind: "toolResult", callId: "call_0", content, isError: true });
  const transcript = opened([
    commit(1, {
      blocks: [{ kind: "toolCall", ...call }, { kind: "toolCall", ...call }, error("cut 1"), error("cut 2")],
      answer: answer("length"),
    }),
    commit(2, { blocks: [{ kind: "toolCall", ...call }], answer: answer("toolCalls") }),
    commit(3, {
      blocks: [error("the turn stopped")],
      end: { kind: "failed", error: "the turn stopped before it saved its end" },
    }),
  ]);
  const tools = transcript.entries.filter((entry) => entry.kind === "tool");
  assertEquals(
    tools.map((entry) => [entry.id, entry.status, entry.result?.content]),
    [
      ["1:0", "done", "cut 1"],
      ["1:1", "done", "cut 2"],
      ["2:0", "done", "the turn stopped"],
    ],
  );
});

test("a page that starts mid-turn pairs its results after the older page", () => {
  const transcript = opened(saved.slice(3));
  assertEquals([transcript.first, keys(transcript)], [4, ["5:0", "6:end"]]);
  const later = transcript.entries[0];
  transcript.insert(saved.slice(0, 3));
  assertEquals(transcript.first, 1);
  assertEquals(transcript.entries, turnEntries);
  assert(transcript.entries[4] === later, "an unchanged entry keeps its object");
  const full = opened(saved.slice(1));
  const finished = full.entries[3];
  full.insert(saved.slice(0, 1));
  assert(full.entries[3] === finished, "a tool with the same saved result keeps its object");
});

test("a gap names the missing events and insert fills it", () => {
  const transcript = fed(opened(saved.slice(0, 3)), saved.slice(4));
  assertEquals(transcript.gap, { before: 5, limit: 1 });
  transcript.insert(saved.slice(3, 4));
  assertEquals(transcript.gap, undefined);
  assertEquals(transcript.entries, turnEntries);
});

test("a gap fill removes the inputs that its commits consume", () => {
  const accepted = turn[1];
  assert(accepted !== undefined);
  const transcript = fed(opened(saved.slice(0, 1)), [accepted, ...saved.slice(2)]);
  assertEquals([...transcript.pending.keys()], [1]);
  transcript.insert(saved.slice(1, 2));
  assertEquals([...transcript.pending.keys()], []);
});

test("a cancel mid-draft keeps only what its commit saved", () => {
  const transcript = fed(opened(), [
    ...turn.slice(0, 11),
    commit(3, { blocks: [{ kind: "assistantText", text: "I run " }], end: { kind: "cancelled" } }),
    { sessionUpdate: "draftDiscarded", draftId: "d1", reason: "failed" },
  ]);
  assertEquals(transcript.entries, [
    input,
    { kind: "text", id: "3:0", text: "I run ", refusal: false, draft: false },
    { kind: "end", id: "3:end", end: { kind: "cancelled" }, answer: undefined },
  ]);
});

test("an end keeps the last saved answer before it, and the next end without an answer has none", () => {
  const first = { ...answer("toolCalls"), origin: { model: "first", baseUrl: "https://p" } };
  const last = { ...answer("stop"), origin: { model: "last", baseUrl: "https://p" } };
  const transcript = opened([
    commit(1, { blocks: [{ kind: "toolCall", ...call }], answer: first }),
    commit(2, { blocks: [{ kind: "assistantText", text: "done" }], answer: last }),
    commit(3, { end: { kind: "cancelled" } }),
    commit(4, { end: { kind: "cancelled" } }),
  ]);
  const ends = transcript.entries.filter((entry) => entry.kind === "end");
  assertEquals(
    ends.map((entry) => entry.answer?.origin.model),
    ["last", undefined],
  );
});

test("an older page gives an end its answer, and an end without a change keeps its object", () => {
  const saved = commit(1, { blocks: [{ kind: "assistantText", text: "done" }], answer: answer("stop") });
  const transcript = opened([commit(2, { end: { kind: "cancelled" } }), commit(3, { end: { kind: "cancelled" } })]);
  const [end, other] = transcript.entries;
  transcript.insert([saved]);
  const after = transcript.entries.filter((entry) => entry.kind === "end");
  assertEquals([after[0]?.answer?.origin.model, after[0] === end, after[1] === other], ["m", false, true]);
});

test("a context replacement adds a marker and keeps the entries before it", () => {
  const transcript = fed(opened(saved), [
    commit(7, { replaced: { head: [{ kind: "userText", text: "<context_summary>…" }], keep: 0 } }),
  ]);
  assertEquals(keys(transcript), ["2:0", "3:0", "3:1", "3:2", "5:0", "6:end", "7:replaced"]);
});

test("a change puts a new object only in the place of its entry", () => {
  const transcript = fed(opened(), turn.slice(0, 11));
  const before = [...transcript.entries];
  fed(transcript, turn.slice(11, 12));
  assertEquals(
    transcript.entries.map((entry, index) => entry === before[index]),
    [true, true, false],
  );
});

test("the updates of a draft that started before the snapshot add nothing", () => {
  const transcript = fed(opened(saved.slice(0, 2)), turn.slice(9, 12));
  assertEquals(keys(transcript), ["2:0"]);
  fed(transcript, turn.slice(17, 18));
  assertEquals(keys(transcript), ["2:0", "3:0", "3:1", "3:2"]);
});

test("an unconfirmed turn drops its draft and the live state of its tools", () => {
  const transcript = fed(opened(), [
    ...turn.slice(0, 21),
    { sessionUpdate: "draftStarted", draftId: "d2" },
    model("d2", { kind: "blockStarted", blockId: 0, content: { kind: "text" } }),
    { sessionUpdate: "turnUnconfirmed" },
  ]);
  assertEquals(keys(transcript), ["2:0", "3:0", "3:1", "3:2"]);
  assertEquals([tool(transcript, 3).status, tool(transcript, 3).output], ["waiting", ""]);
});

test("a running tool has its start timestamp, and a finished tool has its duration", () => {
  const before = Date.now();
  const transcript = fed(opened(), turn.slice(0, 20));
  const running = tool(transcript, 3);
  assert(running.startedAt !== undefined && running.startedAt >= before, `${running.startedAt}`);
  fed(transcript, [
    { sessionUpdate: "toolFinished", position: position(3, 2), result, display: [], durationMs: 40_000 },
  ]);
  assertEquals([tool(transcript, 3).startedAt, tool(transcript, 3).durationMs], [undefined, 40_000]);
});

test("a saved duration without display blocks gives a tool with its duration and no display", () => {
  const timed = commit(4, {
    blocks: [{ kind: "toolResult", ...result }],
    display: { calls: [], results: [{ blockIndex: 0, blocks: [], durationMs: 40_000 }] },
  });
  const transcript = opened([...saved.slice(0, 3), timed]);
  const entry = tool(transcript, 3);
  assertEquals([entry.durationMs, entry.startedAt, entry.display], [40_000, undefined, []]);
});

test("a saved result without a duration has no duration", () => {
  const unmeasured = commit(4, { blocks: [{ kind: "toolResult", ...result }] });
  assertEquals(tool(opened([...saved.slice(0, 3), unmeasured]), 3).durationMs, undefined);
});

test("a gap fill keeps the start timestamp of a running tool", () => {
  const transcript = opened(saved.slice(0, 1));
  fed(transcript, saved.slice(2, 3));
  // The output makes the tool differ from its saved form, so only the rule for a waiting tool keeps it.
  fed(transcript, [
    { sessionUpdate: "toolStarted", position: position(3, 2), call },
    { sessionUpdate: "toolOutput", position: position(3, 2), text: "running" },
  ]);
  const started = tool(transcript, 2).startedAt;
  assert(started !== undefined, "the tool has no start timestamp");
  transcript.insert(saved.slice(1, 2));
  assertEquals(tool(transcript, 3).startedAt, started);
});

test("an unconfirmed turn drops the start timestamps and the durations of its tools", () => {
  const transcript = fed(opened(), [
    ...turn.slice(0, 20),
    { sessionUpdate: "toolFinished", position: position(3, 2), result, display: [], durationMs: 40_000 },
    { sessionUpdate: "turnUnconfirmed" },
  ]);
  assertEquals([tool(transcript, 3).startedAt, tool(transcript, 3).durationMs], [undefined, undefined]);
});

test("the inputs, questions, failure, and settings follow their updates", () => {
  const transcript = opened();
  const facts = () => [
    transcript.state,
    [...transcript.pending.keys()],
    [...transcript.interactions.keys()],
    transcript.failure,
    transcript.settings?.model.model,
  ];
  fed(transcript, turn.slice(0, 3));
  fed(transcript, [
    {
      sessionUpdate: "interactionRequested",
      interactionId: 7,
      source: "ask",
      request: {
        kind: "questions",
        questions: [{ id: "go", header: "Go", question: "t", options: [{ label: "Yes" }, { label: "No" }] }],
      },
    },
    { sessionUpdate: "retryScheduled", afterMs: 3000, error: "overloaded" },
  ]);
  assertEquals(facts(), ["running", [1], [7], { kind: "retryScheduled", afterMs: 3000, error: "overloaded" }, "m"]);
  fed(transcript, [...turn.slice(3, 5), { sessionUpdate: "interactionClosed", interactionId: 7 }]);
  assertEquals(facts(), ["running", [], [], undefined, "m"]);
  fed(transcript, [{ seq: 3, sessionUpdate: "settings", ...settings, model: { provider: "p", model: "n" } }]);
  assertEquals(facts(), ["running", [], [], undefined, "n"]);
  // The snapshot and the live events give the settings. An older page holds older settings.
  const paged = opened([{ seq: 7, sessionUpdate: "settings", ...settings, model: { provider: "p", model: "n" } }]);
  paged.insert(saved);
  assertEquals(paged.settings?.model.model, "n");
});

test("a deferred tool shows the tool that its bridge call names", () => {
  const bridge: ToolCall = { callId: "c", name: "tool_call", arguments: '{"name":"grep","arguments":{"pattern":"x"}}' };
  const transcript = opened([commit(1, { blocks: [{ kind: "toolCall", ...bridge }], answer: answer("toolCalls") })]);
  assertEquals([tool(transcript, 0).name, tool(transcript, 0).arguments], ["grep", '{"pattern":"x"}']);
});

test("usage is the token counts of the last saved answer, and a replaced context or a snapshot clears it", () => {
  const counts = (input: number) => ({ input, output: 10 });
  const withUsage = (input: number): Answer => ({ ...answer("stop"), usage: counts(input) });
  const transcript = new Transcript();
  transcript.apply({ kind: "snapshot", snapshot: { settings, updates: [commit(2, { answer: withUsage(100) })] } });
  const first = transcript.usage?.input;
  transcript.apply({ kind: "update", update: commit(3, { answer: withUsage(200) }) });
  transcript.apply({ kind: "update", update: commit(4, { blocks: [userText] }) });
  const last = transcript.usage?.input;
  transcript.apply({ kind: "update", update: commit(5, { replaced: { head: [userText], keep: 0 } }) });
  const compacted = transcript.usage;
  transcript.apply({ kind: "update", update: commit(6, { answer: withUsage(300) }) });
  const next = transcript.usage?.input;
  transcript.apply({ kind: "snapshot", snapshot: { settings, updates: [] } });
  assertEquals([first, last, compacted, next, transcript.usage], [100, 200, undefined, 300, undefined]);
});
