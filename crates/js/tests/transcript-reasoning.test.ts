import type {
  Answer,
  Block,
  Commit,
  ConsumedInput,
  DraftId,
  FinishReason,
  LiveUpdate,
  ModelUpdate,
  SessionSettings,
  SessionUpdate,
  StoredEvent,
  ToolCall,
} from "yuke:protocol";
import { assert, equal, test } from "yuke:test";
import { Transcript, type Entry as TranscriptEntry } from "yuke:transcript";

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

function model(draftId: DraftId, event: ModelUpdate): LiveUpdate {
  return { sessionUpdate: "model", draftId, event };
}

function opened(updates: SessionUpdate[] = []): Transcript {
  const transcript = new Transcript();
  transcript.apply({ snapshot: { settings, updates } });
  return transcript;
}

function fed(transcript: Transcript, updates: readonly SessionUpdate[]): Transcript {
  for (const update of updates) transcript.apply({ update });
  return transcript;
}

function reasoning(transcript: Transcript): Extract<TranscriptEntry, { kind: "reasoning" }>[] {
  return transcript.entries.filter(
    (entry): entry is Extract<TranscriptEntry, { kind: "reasoning" }> => entry.kind === "reasoning",
  );
}

function answer(finishReason: FinishReason): Answer {
  return {
    origin: { model: "m", baseUrl: "https://p" },
    usage: { input: null, output: null, reasoning: null, cacheRead: null, cacheWrite: null },
    finishReason,
  };
}

const call: ToolCall = { callId: "call_0", name: "bash", arguments: '{"command":"true"}' };
const userText: Block = { user_text: "hello" };

// A saved reasoning entry uses the source position of its first block, not a new position for the group.
test("saved consecutive reasoning blocks group within a commit and stop at boundaries", () => {
  const replay = {
    origin: { model: "m", baseUrl: "https://p" },
    kind: "responses_encrypted" as const,
    data: "first-provider-state",
  };
  const firstBlocks: Block[] = [
    { reasoning: { text: "  first  ", replay } },
    { reasoning: { text: "second", replay: { ...replay, data: "second-provider-state" } } },
    { assistant_text: "response" },
    { reasoning: { text: "" } },
    { reasoning: { text: "  after  " } },
    { tool_call: call },
    { reasoning: { text: "tail" } },
  ];
  const first = commit(1, { blocks: firstBlocks, answer: answer("tool_calls") });
  const second = commit(2, { blocks: [{ reasoning: { text: "next" } }, { reasoning: { text: "last" } }] });

  const original = JSON.stringify([first, second]);
  const transcript = opened([first, second]);

  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [
      ["1:0", "  first  \n\nsecond"],
      ["1:3", "  after  "],
      ["1:6", "tail"],
      ["2:0", "next\n\nlast"],
    ],
  );
  equal(JSON.stringify([first, second]), original);
});

test("saved all-empty reasoning runs are omitted, while a live run remains visible", () => {
  const transcript = opened([commit(1, { blocks: [{ reasoning: { text: "" } }, { reasoning: { text: " \t\n " } }] })]);
  equal(reasoning(transcript), []);

  fed(transcript, [
    { sessionUpdate: "draft_started", draftId: "empty" },
    model("empty", { kind: "block_started", block: 4, content: { kind: "reasoning" } }),
  ]);
  const entry = reasoning(transcript)[0];
  equal(entry, { kind: "reasoning", key: "draft:empty:4", text: "", draft: true });
  assert(entry !== undefined, "the live empty reasoning run is missing");
});

test("a live group keeps its first key and only changes when its retained text changes", () => {
  const transcript = opened();
  fed(transcript, [
    { sessionUpdate: "draft_started", draftId: "d1" },
    model("d1", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoning_delta", block: 0, text: "  first  " }),
  ]);
  const first = reasoning(transcript)[0];
  assert(first !== undefined, "the first reasoning group is missing");

  fed(transcript, [
    model("d1", { kind: "block_started", block: 1, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoning_delta", block: 1, text: " \t" }),
  ]);
  assert(reasoning(transcript)[0] === first, "starting an empty source block replaced the group");
  equal(reasoning(transcript)[0]?.text, "  first  ");

  fed(transcript, [model("d1", { kind: "reasoning_delta", block: 1, text: "second" })]);
  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [["draft:d1:0", "  first  \n\n \tsecond"]],
  );

  fed(transcript, [model("d1", { kind: "reasoning_delta", block: 1, text: "tail" })]);
  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [["draft:d1:0", "  first  \n\n \tsecondtail"]],
  );
});

test("interleaved reasoning deltas route back to their source group", () => {
  const transcript = fed(opened(), [
    { sessionUpdate: "draft_started", draftId: "interleaved" },
    model("interleaved", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("interleaved", { kind: "reasoning_delta", block: 0, text: "one" }),
    model("interleaved", { kind: "block_started", block: 1, content: { kind: "reasoning" } }),
    model("interleaved", { kind: "reasoning_delta", block: 1, text: "two" }),
    model("interleaved", { kind: "block_started", block: 2, content: { kind: "text" } }),
    model("interleaved", { kind: "text_delta", block: 2, text: "answer" }),
    model("interleaved", { kind: "reasoning_delta", block: 0, text: " late" }),
  ]);

  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [["draft:interleaved:0", "one late\n\ntwo"]],
  );
});

test("live grouped reasoning and replayed saved reasoning end equal", () => {
  const saved = commit(4, {
    blocks: [{ reasoning: { text: "first" } }, { reasoning: { text: "second" } }, { assistant_text: "answer" }],
  });
  const updates: SessionUpdate[] = [
    { sessionUpdate: "draft_started", draftId: "d1" },
    model("d1", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoning_delta", block: 0, text: "first" }),
    model("d1", { kind: "block_started", block: 1, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoning_delta", block: 1, text: "second" }),
    model("d1", { kind: "block_started", block: 2, content: { kind: "text" } }),
    model("d1", { kind: "text_delta", block: 2, text: "answer" }),
    saved,
    { sessionUpdate: "draft_committed", draftId: "d1", eventNumber: 4, blocks: [0, 1, 2] },
  ];
  const live = fed(opened(), updates);
  const replay = opened([saved]);

  equal(live.entries, replay.entries);
  equal(
    reasoning(live).map((entry) => entry.key),
    ["4:0"],
  );
});

test("draft discard and replacement do not remove saved neighbors", () => {
  const transcript = opened([commit(1, { blocks: [{ reasoning: { text: "saved" } }] })]);
  fed(transcript, [
    { sessionUpdate: "draft_started", draftId: "discarded" },
    model("discarded", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("discarded", { kind: "block_started", block: 1, content: { kind: "reasoning" } }),
    model("discarded", { kind: "reasoning_delta", block: 1, text: "not saved" }),
    { sessionUpdate: "draft_discarded", draftId: "discarded", reason: "failed" },
  ]);
  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [["1:0", "saved"]],
  );

  fed(transcript, [
    { sessionUpdate: "draft_started", draftId: "cancelled" },
    model("cancelled", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("cancelled", { kind: "reasoning_delta", block: 0, text: "cancelled" }),
    commit(2, { blocks: [{ reasoning: { text: "cancelled" } }], end: { outcome: "cancelled" } }),
    { sessionUpdate: "draft_discarded", draftId: "cancelled", reason: "failed" },
  ]);
  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [
      ["1:0", "saved"],
      ["2:0", "cancelled"],
    ],
  );

  fed(transcript, [
    { sessionUpdate: "draft_started", draftId: "replacement" },
    model("replacement", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("replacement", { kind: "reasoning_delta", block: 0, text: "replacement" }),
    commit(3, { blocks: [{ reasoning: { text: "replacement" } }] }),
    { sessionUpdate: "draft_committed", draftId: "replacement", eventNumber: 3, blocks: [0] },
  ]);
  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [
      ["1:0", "saved"],
      ["2:0", "cancelled"],
      ["3:0", "replacement"],
    ],
  );

  fed(transcript, [
    { sessionUpdate: "draft_started", draftId: "unconfirmed" },
    model("unconfirmed", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    { sessionUpdate: "turn_unconfirmed" },
  ]);
  equal(
    reasoning(transcript).map((entry) => entry.key),
    ["1:0", "2:0", "3:0"],
  );
});

test("input, end, compaction, refusal, and tools keep reasoning runs apart", () => {
  const transcript = opened([
    commit(1, { blocks: [userText, { reasoning: { text: "before" } }] }, [
      { id: 1, source: { kind: "user" }, kind: "message", blockCount: 1 },
    ]),
    commit(2, {
      blocks: [
        { reasoning: { text: "turn" } },
        { reasoning: { text: "end" } },
        { assistant_text: "no" },
        { reasoning: { text: "after refusal" } },
        { tool_call: call },
        { reasoning: { text: "after tool" } },
      ],
      answer: answer("refusal"),
      end: { outcome: "cancelled" },
    }),
    commit(3, { replaced: { head: [{ user_text: "summary" }], keep: 0 } }),
    commit(4, { blocks: [{ reasoning: { text: "next" } }, { reasoning: { text: "part" } }] }),
  ]);

  equal(
    reasoning(transcript).map((entry) => [entry.key, entry.text]),
    [
      ["1:1", "before"],
      ["2:0", "turn\n\nend"],
      ["2:3", "after refusal"],
      ["2:5", "after tool"],
      ["4:0", "next\n\npart"],
    ],
  );
  equal(
    transcript.entries.map((entry) => entry.kind),
    ["input", "reasoning", "reasoning", "text", "reasoning", "tool", "reasoning", "end", "compaction", "reasoning"],
  );
});

test("inserting older and gap events preserves a live group and tool state", () => {
  const newer = commit(3, {
    blocks: [{ reasoning: { text: "saved one" } }, { reasoning: { text: "saved two" } }, { tool_call: call }],
    answer: answer("tool_calls"),
  });
  const transcript = opened([newer]);
  fed(transcript, [
    { sessionUpdate: "tool_started", execution: { eventNumber: 3, blockIndex: 2 }, call },
    { sessionUpdate: "tool_output", execution: { eventNumber: 3, blockIndex: 2 }, text: "running" },
    { sessionUpdate: "draft_started", draftId: "live" },
    model("live", { kind: "block_started", block: 0, content: { kind: "reasoning" } }),
    model("live", { kind: "reasoning_delta", block: 0, text: "draft one" }),
    model("live", { kind: "block_started", block: 1, content: { kind: "reasoning" } }),
    model("live", { kind: "reasoning_delta", block: 1, text: "draft two" }),
    model("live", { kind: "block_started", block: 2, content: { kind: "tool_call", name: "bash" } }),
    model("live", { kind: "tool_input_delta", block: 2, text: "{}" }),
    model("live", { kind: "block_stopped", block: 2, call }),
  ]);
  const savedTool = transcript.entries.find((entry) => entry.key === "3:2");
  assert(savedTool?.kind === "tool", "the saved tool is missing");
  const startedAt = savedTool.startedAt;
  assert(startedAt !== undefined, "the running tool has no start timestamp");

  transcript.insert([commit(1, { blocks: [{ assistant_text: "older" }] })]);
  equal(transcript.gap, { before: 3, limit: 1 });
  transcript.insert([commit(2, { blocks: [{ assistant_text: "gap" }] })]);
  equal(transcript.gap, undefined);

  fed(transcript, [model("live", { kind: "reasoning_delta", block: 0, text: " late" })]);
  equal(reasoning(transcript).at(-1), {
    kind: "reasoning",
    key: "draft:live:0",
    text: "draft one late\n\ndraft two",
    draft: true,
  });
  const savedToolAfter = transcript.entries.find((entry) => entry.key === "3:2");
  assert(savedToolAfter?.kind === "tool", "the saved tool disappeared after insertion");
  equal([savedToolAfter.status, savedToolAfter.output, savedToolAfter.startedAt], ["running", "running", startedAt]);
});
