import type { Block, SessionUpdate, ToolCall } from "yuke:protocol";
import { assert, assertEquals, test } from "yuke:test";
import type { Transcript, Entry as TranscriptEntry } from "yuke:transcript";
import { answer, commit, fed, model, opened } from "./transcript-fixtures.ts";

function reasoning(transcript: Transcript): Extract<TranscriptEntry, { kind: "reasoning" }>[] {
  return transcript.entries.filter(
    (entry): entry is Extract<TranscriptEntry, { kind: "reasoning" }> => entry.kind === "reasoning",
  );
}

const call: ToolCall = { callId: "call_0", name: "bash", arguments: '{"command":"true"}' };
const userText: Block = { kind: "userText", text: "hello" };

// A saved reasoning entry uses the source position of its first block, not a new position for the group.
test("saved consecutive reasoning blocks group within a commit and stop at boundaries", () => {
  const replay = {
    origin: { model: "m", baseUrl: "https://p" },
    kind: "responsesEncrypted" as const,
    data: "first-provider-state",
  };
  const firstBlocks: Block[] = [
    { kind: "reasoning", text: "  first  ", replay },
    { kind: "reasoning", text: "second", replay: { ...replay, data: "second-provider-state" } },
    { kind: "assistantText", text: "response" },
    { kind: "reasoning", text: "" },
    { kind: "reasoning", text: "  after  " },
    { kind: "toolCall", ...call },
    { kind: "reasoning", text: "tail" },
  ];
  const first = commit(1, { blocks: firstBlocks, answer: answer("toolCalls") });
  const second = commit(2, {
    blocks: [
      { kind: "reasoning", text: "next" },
      { kind: "reasoning", text: "last" },
    ],
  });

  const original = JSON.stringify([first, second]);
  const transcript = opened([first, second]);

  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [
      ["1:0", "  first  \n\nsecond"],
      ["1:3", "  after  "],
      ["1:6", "tail"],
      ["2:0", "next\n\nlast"],
    ],
  );
  assertEquals(JSON.stringify([first, second]), original);
});

test("saved all-empty reasoning runs are omitted, while a live run remains visible", () => {
  const transcript = opened([
    commit(1, {
      blocks: [
        { kind: "reasoning", text: "" },
        { kind: "reasoning", text: " \t\n " },
      ],
    }),
  ]);
  assertEquals(reasoning(transcript), []);

  fed(transcript, [
    { sessionUpdate: "draftStarted", draftId: "empty" },
    model("empty", { kind: "blockStarted", blockId: 4, content: { kind: "reasoning" } }),
  ]);
  const entry = reasoning(transcript)[0];
  assertEquals(entry, { kind: "reasoning", id: "draft:empty:4", text: "", draft: true });
  assert(entry !== undefined, "the live empty reasoning run is missing");
});

test("a live group keeps its first key and only changes when its retained text changes", () => {
  const transcript = opened();
  fed(transcript, [
    { sessionUpdate: "draftStarted", draftId: "d1" },
    model("d1", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoningDelta", blockId: 0, text: "  first  " }),
  ]);
  const first = reasoning(transcript)[0];
  assert(first !== undefined, "the first reasoning group is missing");

  fed(transcript, [
    model("d1", { kind: "blockStarted", blockId: 1, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoningDelta", blockId: 1, text: " \t" }),
  ]);
  assert(reasoning(transcript)[0] === first, "starting an empty source block replaced the group");
  assertEquals(reasoning(transcript)[0]?.text, "  first  ");

  fed(transcript, [model("d1", { kind: "reasoningDelta", blockId: 1, text: "second" })]);
  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [["draft:d1:0", "  first  \n\n \tsecond"]],
  );

  fed(transcript, [model("d1", { kind: "reasoningDelta", blockId: 1, text: "tail" })]);
  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [["draft:d1:0", "  first  \n\n \tsecondtail"]],
  );
});

test("interleaved reasoning deltas route back to their source group", () => {
  const transcript = fed(opened(), [
    { sessionUpdate: "draftStarted", draftId: "interleaved" },
    model("interleaved", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("interleaved", { kind: "reasoningDelta", blockId: 0, text: "one" }),
    model("interleaved", { kind: "blockStarted", blockId: 1, content: { kind: "reasoning" } }),
    model("interleaved", { kind: "reasoningDelta", blockId: 1, text: "two" }),
    model("interleaved", { kind: "blockStarted", blockId: 2, content: { kind: "text" } }),
    model("interleaved", { kind: "textDelta", blockId: 2, text: "answer" }),
    model("interleaved", { kind: "reasoningDelta", blockId: 0, text: " late" }),
  ]);

  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [["draft:interleaved:0", "one late\n\ntwo"]],
  );
});

test("live grouped reasoning and replayed saved reasoning end equal", () => {
  const saved = commit(4, {
    blocks: [
      { kind: "reasoning", text: "first" },
      { kind: "reasoning", text: "second" },
      { kind: "assistantText", text: "answer" },
    ],
  });
  const updates: SessionUpdate[] = [
    { sessionUpdate: "draftStarted", draftId: "d1" },
    model("d1", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoningDelta", blockId: 0, text: "first" }),
    model("d1", { kind: "blockStarted", blockId: 1, content: { kind: "reasoning" } }),
    model("d1", { kind: "reasoningDelta", blockId: 1, text: "second" }),
    model("d1", { kind: "blockStarted", blockId: 2, content: { kind: "text" } }),
    model("d1", { kind: "textDelta", blockId: 2, text: "answer" }),
    saved,
    { sessionUpdate: "draftCommitted", draftId: "d1", eventNumber: 4, blocks: [0, 1, 2] },
  ];
  const live = fed(opened(), updates);
  const replay = opened([saved]);

  assertEquals(live.entries, replay.entries);
  assertEquals(
    reasoning(live).map((entry) => entry.id),
    ["4:0"],
  );
});

test("draft discard and replacement do not remove saved neighbors", () => {
  const transcript = opened([commit(1, { blocks: [{ kind: "reasoning", text: "saved" }] })]);
  fed(transcript, [
    { sessionUpdate: "draftStarted", draftId: "discarded" },
    model("discarded", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("discarded", { kind: "blockStarted", blockId: 1, content: { kind: "reasoning" } }),
    model("discarded", { kind: "reasoningDelta", blockId: 1, text: "not saved" }),
    { sessionUpdate: "draftDiscarded", draftId: "discarded", reason: "failed" },
  ]);
  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [["1:0", "saved"]],
  );

  fed(transcript, [
    { sessionUpdate: "draftStarted", draftId: "cancelled" },
    model("cancelled", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("cancelled", { kind: "reasoningDelta", blockId: 0, text: "cancelled" }),
    commit(2, { blocks: [{ kind: "reasoning", text: "cancelled" }], end: { kind: "cancelled" } }),
    { sessionUpdate: "draftDiscarded", draftId: "cancelled", reason: "failed" },
  ]);
  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [
      ["1:0", "saved"],
      ["2:0", "cancelled"],
    ],
  );

  fed(transcript, [
    { sessionUpdate: "draftStarted", draftId: "replacement" },
    model("replacement", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("replacement", { kind: "reasoningDelta", blockId: 0, text: "replacement" }),
    commit(3, { blocks: [{ kind: "reasoning", text: "replacement" }] }),
    { sessionUpdate: "draftCommitted", draftId: "replacement", eventNumber: 3, blocks: [0] },
  ]);
  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [
      ["1:0", "saved"],
      ["2:0", "cancelled"],
      ["3:0", "replacement"],
    ],
  );

  fed(transcript, [
    { sessionUpdate: "draftStarted", draftId: "unconfirmed" },
    model("unconfirmed", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    { sessionUpdate: "turnUnconfirmed" },
  ]);
  assertEquals(
    reasoning(transcript).map((entry) => entry.id),
    ["1:0", "2:0", "3:0"],
  );
});

test("input, end, compaction, refusal, and tools keep reasoning runs apart", () => {
  const transcript = opened([
    commit(1, { blocks: [userText, { kind: "reasoning", text: "before" }] }, [
      { id: 1, source: { kind: "user" }, kind: "message", blockCount: 1 },
    ]),
    commit(2, {
      blocks: [
        { kind: "reasoning", text: "turn" },
        { kind: "reasoning", text: "end" },
        { kind: "assistantText", text: "no" },
        { kind: "reasoning", text: "after refusal" },
        { kind: "toolCall", ...call },
        { kind: "reasoning", text: "after tool" },
      ],
      answer: answer("refusal"),
      end: { kind: "cancelled" },
    }),
    commit(3, { replaced: { head: [{ kind: "userText", text: "summary" }], keep: 0 } }),
    commit(4, {
      blocks: [
        { kind: "reasoning", text: "next" },
        { kind: "reasoning", text: "part" },
      ],
    }),
  ]);

  assertEquals(
    reasoning(transcript).map((entry) => [entry.id, entry.text]),
    [
      ["1:1", "before"],
      ["2:0", "turn\n\nend"],
      ["2:3", "after refusal"],
      ["2:5", "after tool"],
      ["4:0", "next\n\npart"],
    ],
  );
  assertEquals(
    transcript.entries.map((entry) => entry.kind),
    ["input", "reasoning", "reasoning", "text", "reasoning", "tool", "reasoning", "end", "compaction", "reasoning"],
  );
});

test("inserting older and gap events preserves a live group and tool state", () => {
  const newer = commit(3, {
    blocks: [
      { kind: "reasoning", text: "saved one" },
      { kind: "reasoning", text: "saved two" },
      { kind: "toolCall", ...call },
    ],
    answer: answer("toolCalls"),
  });
  const transcript = opened([newer]);
  fed(transcript, [
    { sessionUpdate: "toolStarted", position: { eventNumber: 3, blockIndex: 2 }, call },
    { sessionUpdate: "toolOutput", position: { eventNumber: 3, blockIndex: 2 }, text: "running" },
    { sessionUpdate: "draftStarted", draftId: "live" },
    model("live", { kind: "blockStarted", blockId: 0, content: { kind: "reasoning" } }),
    model("live", { kind: "reasoningDelta", blockId: 0, text: "draft one" }),
    model("live", { kind: "blockStarted", blockId: 1, content: { kind: "reasoning" } }),
    model("live", { kind: "reasoningDelta", blockId: 1, text: "draft two" }),
    model("live", { kind: "blockStarted", blockId: 2, content: { kind: "toolCall", name: "bash" } }),
    model("live", { kind: "toolInputDelta", blockId: 2, text: "{}" }),
    model("live", { kind: "blockStopped", blockId: 2, call }),
  ]);
  const savedTool = transcript.entries.find((entry) => entry.id === "3:2");
  assert(savedTool?.kind === "tool", "the saved tool is missing");
  const startedAt = savedTool.startedAt;
  assert(startedAt !== undefined, "the running tool has no start timestamp");

  transcript.insert([commit(1, { blocks: [{ kind: "assistantText", text: "older" }] })]);
  assertEquals(transcript.missingEvents, { before: 3, limit: 1 });
  transcript.insert([commit(2, { blocks: [{ kind: "assistantText", text: "gap" }] })]);
  assertEquals(transcript.missingEvents, undefined);

  fed(transcript, [model("live", { kind: "reasoningDelta", blockId: 0, text: " late" })]);
  assertEquals(reasoning(transcript).at(-1), {
    kind: "reasoning",
    id: "draft:live:0",
    text: "draft one late\n\ndraft two",
    draft: true,
  });
  const savedToolAfter = transcript.entries.find((entry) => entry.id === "3:2");
  assert(savedToolAfter?.kind === "tool", "the saved tool disappeared after insertion");
  assertEquals(
    [savedToolAfter.status, savedToolAfter.output, savedToolAfter.startedAt],
    ["running", "running", startedAt],
  );
});
