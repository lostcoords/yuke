// The tool calls of the bundled chat: the head line, the previews, the body, the diffs, the folds, and the links.

import type { Block, DisplayBlock, StoredEvent, ToolHints, ToolResult } from "yuke:protocol";
import { assert, createFrame, equal, settled, test } from "yuke:test";
import {
  click,
  commit,
  fakeSessions,
  fixedClock,
  loadChat,
  mouse,
  SETTINGS,
  themeStyle,
  transcriptRows,
} from "./chat.ts";
import { rows } from "./rows.ts";

/** The lines `<word> 1` to `<word> <count>`. */
function lines(word: string, count: number): string {
  return Array.from({ length: count }, (_, at) => `${word} ${at + 1}`).join("\n");
}

/** One tool call of a test: its name, arguments, hints, and result. */
interface Call {
  readonly name: string;
  readonly args: unknown;
  readonly hints: ToolHints;
  readonly result: ToolResult;
  readonly display?: DisplayBlock[];
  /** The folder of the call. The default is /tools. */
  readonly folder?: string | null;
  readonly durationMs?: number;
}

/** A session with each call of `calls` in its own event, and its result in the next event. */
function calls(...called: Call[]): StoredEvent[] {
  const saved: StoredEvent[] = [{ seq: 1, sessionUpdate: "settings", ...SETTINGS }];
  for (const [at, call] of called.entries()) {
    const callId = `c${at}`;
    const block: Block = { tool_call: { callId, name: call.name, arguments: JSON.stringify(call.args) } };
    // The calls run in /tools, and the session works in /w.
    const hints = {
      calls: [{ blockIndex: 0, hints: call.hints, folder: call.folder === undefined ? "/tools" : call.folder }],
      results: [],
    };
    saved.push(commit(saved.length + 1, [block], { display: hints }));
    const result: Block = { tool_result: { ...call.result, callId } };
    const shown =
      call.display === undefined && call.durationMs === undefined
        ? []
        : [{ blockIndex: 0, blocks: call.display ?? [], durationMs: call.durationMs ?? null }];
    saved.push(commit(saved.length + 1, [result], { display: { calls: [], results: shown } }));
  }
  return saved;
}

const READ: ToolHints = { title: null, subject: { argument: "path", kind: "file" }, preview: "none" };
const EXEC: ToolHints = { title: null, subject: { argument: "command", kind: "text" }, preview: "tail" };
const PROBE: ToolHints = { title: "Probe", subject: null, preview: "head" };
const PROBE_FILE: ToolHints = { title: null, subject: { argument: "path", kind: "file" }, preview: "head" };

const ok = (content: string): ToolResult => ({ callId: "", content, isError: false });

test("a folded call shows the head line and the preview of its hints, and an error shows its first rows", async () => {
  using frame = createFrame({ width: 30, height: 40 }, undefined, { cwd: "/w", session: "s1" });
  const long = "x".repeat(50);
  const saved = calls(
    { name: "read", args: { path: "src/main.rs" }, hints: READ, result: ok(lines("line", 30)) },
    { name: "exec", args: { command: "npm test" }, hints: EXEC, result: ok(`${lines("out", 4)}\n${long}`) },
    { name: "probe", args: {}, hints: PROBE, result: ok(lines("row", 12)) },
    { name: "fail", args: {}, hints: READ, result: { callId: "", content: lines("err", 11), isError: true } },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 37), [
    "",
    " read src/main.rs",
    "",
    " exec npm test",
    // The long line wraps at 28 cells, so its two rows count in the tail.
    " … 1 more lines",
    " out 2",
    " out 3",
    " out 4",
    ` ${"x".repeat(28)}`,
    ` ${"x".repeat(22)}`,
    "",
    " Probe",
    ...lines(" row", 10).split("\n"),
    " … 2 more lines",
    "",
    " fail · error",
    ...lines(" err", 10).split("\n"),
    " … 1 more lines",
    "",
  ]);
});

test("a folded preview counts a line that it cuts as one more line", async () => {
  using frame = createFrame({ width: 30, height: 40 }, undefined, { cwd: "/w", session: "s1" });
  // At 28 cells, the line of 70 cells has 3 rows, and the line of 150 cells has 6 rows.
  const long = "x".repeat(70);
  const saved = calls(
    { name: "probe", args: {}, hints: PROBE, result: ok(`${lines("row", 9)}\n${long}\n${lines("end", 2)}`) },
    { name: "exec", args: { command: "make" }, hints: EXEC, result: ok(`start\n${"y".repeat(150)}`) },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(1, 21), [
    " Probe",
    ...lines(" row", 9).split("\n"),
    ` ${"x".repeat(28)}`,
    " … 3 more lines",
    "",
    " exec make",
    // "start" and the cut line of 150 cells.
    " … 2 more lines",
    ...Array(4).fill(` ${"y".repeat(28)}`),
    ` ${"y".repeat(10)}`,
  ]);
});

test("a folded preview keeps a carriage return out of its last line, and a body that fits shows no count", async () => {
  using frame = createFrame({ width: 30, height: 40 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "probe", args: {}, hints: PROBE, result: ok(lines("row", 12).replaceAll("\n", "\r\n")) },
    { name: "exec", args: { command: "make" }, hints: EXEC, result: ok(lines("out", 5)) },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(1, 21), [
    " Probe",
    ...lines(" row", 10).split("\n"),
    " … 2 more lines",
    "",
    " exec make",
    ...lines(" out", 5).split("\n"),
    "",
  ]);
  frame.mouse(mouse(1, 11, "press"));
  frame.mouse(mouse(20, 11, "drag"));
  frame.mouse(mouse(20, 11, "release"));
  equal(frame.copies, ["row 10"]);
});

test("a folded call clips its subject to one row and keeps its state, and an open call shows the whole subject", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const command = "cd crates/js &&\n  mise exec -- tsc -p tsconfig.json";
  const failed = { callId: "", content: "", isError: true };
  const saved = calls({ name: "exec", args: { command }, hints: EXEC, result: failed });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 3), ["", " exec cd crates/js &… · error", ""]);
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 6), [
    "",
    " exec cd crates/js &… · error",
    " cd crates/js &&",
    "   mise exec -- tsc -p",
    " tsconfig.json",
    "",
  ]);
  // A drag over the open rows copies the command with its line ends.
  frame.mouse(mouse(1, 2, "press"));
  frame.mouse(mouse(14, 4, "drag"));
  frame.mouse(mouse(14, 4, "release"));
  equal(frame.copies, [command]);
});

test("a subject that fits in one row copies as it shows, and an open call does not show it twice", async () => {
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls({ name: "exec", args: { command: "npm test" }, hints: EXEC, result: ok("") });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 3), ["", " exec npm test", ""]);
  frame.mouse(mouse(1, 1, "press"));
  frame.mouse(mouse(14, 1, "drag"));
  frame.mouse(mouse(14, 1, "release"));
  equal(frame.copies, ["exec npm test"]);
});

test("a drag over a clipped subject copies the shown text, and its source gives the whole subject", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const command = "cd crates/js && tsc";
  const saved = calls({ name: "exec", args: { command }, hints: EXEC, result: ok("") });
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  frame.mouse(mouse(1, 1, "press"));
  frame.mouse(mouse(19, 1, "drag"));
  frame.mouse(mouse(19, 1, "release"));
  equal(frame.copies, ["exec cd crates/js…"]);
  const transcript = chat.transcript();
  const selection = transcript.selection;
  equal(
    selection === undefined ? undefined : transcript.text({ from: selection.anchor, to: selection.head }, "source"),
    `exec ${command}`,
  );
});

test("a click on a clipped path copies the whole path", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const path = "crates/js/modules/main.ts";
  const saved = calls({ name: "read", args: { path }, hints: READ, result: ok("") });
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 3), ["", " read crates/js/mo…", ""]);
  click(frame, 7, 1);
  equal(chat.notices, [`info copied /tools/${path}`]);
});

test("a subject with a line end that fits in one row still opens below the head line", async () => {
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls({ name: "exec", args: { command: "a\nb" }, hints: EXEC, result: ok("") });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 3), ["", " exec a b", ""]);
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 5), ["", " exec a b", " a", " b", ""]);
});

test("a carriage return in a subject stays out of a copy of the head line", async () => {
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls({ name: "exec", args: { command: "a\r\nb" }, hints: EXEC, result: ok("") });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  frame.mouse(mouse(1, 1, "press"));
  frame.mouse(mouse(10, 1, "drag"));
  frame.mouse(mouse(10, 1, "release"));
  equal(frame.copies, ["exec a  b"]);
});

test("a long title gives way to the state, and a subject without room stays out of the head line", async () => {
  using frame = createFrame({ width: 20, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const hints: ToolHints = { ...EXEC, title: "A title of many words" };
  const failed = { callId: "", content: "", isError: true };
  const saved = calls({ name: "exec", args: { command: "make" }, hints, result: failed });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 3), ["", " A title o… · error", ""]);
});

test("an open call shows only its subject, and a call without a subject hint shows its raw arguments", async () => {
  using frame = createFrame({ width: 40, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "write", args: { path: "a.rs", content: "x" }, hints: READ, result: ok("") },
    { name: "probe", args: { depth: 2 }, hints: PROBE, result: ok("") },
    { name: "probe", args: {}, hints: PROBE, result: ok("") },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 7), ["", " write a.rs", "", ' Probe {"depth":2}', "", " Probe", ""]);
  // Raw arguments have no link, so a click on them copies nothing.
  click(frame, 10, 3);
  equal(frame.copies, []);
});

test("a call without a subject hint shows its incomplete raw arguments", async () => {
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "read", arguments: '{"path":"a' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: PROBE, folder: "/w" }], results: [] },
    }),
  ];
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(1, 2), [' Probe {"path":"a · waiting']);
});

test("a streaming call shows its name and raw arguments, and the subject takes their place when the hints come", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions([{ seq: 1, sessionUpdate: "settings", ...SETTINGS }]);
  await loadChat(frame, sessions);
  frame.start();
  const model = (event: object) => sessions.push({ sessionUpdate: "model", draftId: "d1", event } as never);
  const head = (): string | undefined => {
    frame.draw();
    return transcriptRows(frame)[1];
  };
  sessions.push({ sessionUpdate: "draft_started", draftId: "d1" });
  model({ kind: "block_started", block: 0, content: { kind: "tool_call", name: "exec" } });
  model({ kind: "tool_input_delta", block: 0, text: '{"command":' });
  const streaming = head();
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  model({ kind: "tool_input_delta", block: 0, text: '"make"}' });
  model({ kind: "block_stopped", block: 0, call });
  const stopped = head();
  sessions.push(
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  );
  sessions.push({ sessionUpdate: "draft_committed", draftId: "d1", eventNumber: 2, blocks: [0] });
  equal(
    [streaming, stopped, head()],
    [' exec {"command": · …', ' exec {"command":"make"} · waiting', " exec make · waiting"],
  );
});

test("a tool search that ends well shows no row, and a failed one shows its error", async () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const search: ToolHints = { title: null, subject: null, preview: "head" };
  const saved = calls(
    { name: "tool_search", args: { query: "slack" }, hints: search, result: ok("loaded slack_send") },
    { name: "read", args: { path: "a.rs" }, hints: READ, result: ok("x") },
    { name: "tool_search", args: { query: "jira" }, hints: search, result: { ...ok("no match"), isError: true } },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 6), [
    "",
    " read a.rs",
    "",
    ' tool_search {"query":"jira"} · error',
    " no match",
    "",
  ]);
});

test("the tool toggle folds each shown tool when each one is open, and a hidden tool search does not count", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const search: ToolHints = { title: null, subject: null, preview: "head" };
  const saved = calls(
    { name: "tool_search", args: { query: "read" }, hints: search, result: ok("loaded read") },
    { name: "read", args: { path: "a.rs" }, hints: READ, result: ok("x") },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  click(frame, 2, 1);
  frame.draw();
  const opened = transcriptRows(frame).slice(0, 3);
  frame.key("ctrl+o");
  frame.draw();
  equal(
    [opened, transcriptRows(frame).slice(0, 3)],
    [
      ["", " read a.rs", " x"],
      ["", " read a.rs", ""],
    ],
  );
});

test("a streaming tool search shows no row from its start", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions([{ seq: 1, sessionUpdate: "settings", ...SETTINGS }]);
  await loadChat(frame, sessions);
  frame.start();
  const model = (event: object) => sessions.push({ sessionUpdate: "model", draftId: "d1", event } as never);
  sessions.push({ sessionUpdate: "draft_started", draftId: "d1" });
  model({ kind: "block_started", block: 0, content: { kind: "text" } });
  model({ kind: "text_delta", block: 0, text: "I look for a tool." });
  model({ kind: "block_started", block: 1, content: { kind: "tool_call", name: "tool_search" } });
  model({ kind: "tool_input_delta", block: 1, text: '{"query":' });
  frame.draw();
  equal(transcriptRows(frame), ["", " I look for a tool.", "", "", ""]);
});

test("a failed call with a display shows the display in place of its text", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const hints: ToolHints = { title: "Fetch", subject: { argument: "url", kind: "uri" }, preview: "head" };
  const result = { callId: "", content: '{"errors":[{"status":404}]}', isError: true };
  const display: DisplayBlock[] = [{ kind: "markdown", text: "Page not found (HTTP 404)." }];
  const saved = calls({ name: "fetch", args: { url: "https://a.b/c" }, hints, result, display });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 4), ["", " Fetch https://a.b/c · error", " Page not found (HTTP 404).", ""]);
});

test("the live output of a call gives way to its result at once", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  ];
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  using _clock = fixedClock();
  const execution = { eventNumber: 2, blockIndex: 0 };
  sessions.push({ sessionUpdate: "tool_started", execution, call });
  sessions.push({ sessionUpdate: "tool_output", execution, text: "compiling" });
  frame.draw();
  equal(transcriptRows(frame).slice(0, 4), ["", " exec make · running", " compiling", ""]);
  const result = { callId: "c0", content: "built", isError: false };
  sessions.push({ sessionUpdate: "tool_finished", execution, result, display: [] });
  frame.draw();
  equal(transcriptRows(frame).slice(0, 4), ["", " exec make", " built", ""]);
});

test("a finished call shows its duration, and a call below one second or without a duration shows none", async () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const failed = { ...ok(""), isError: true };
  const saved = calls(
    { name: "exec", args: { command: "a" }, hints: READ, result: ok(""), durationMs: 185_000 },
    { name: "exec", args: { command: "b" }, hints: READ, result: ok(""), durationMs: 999 },
    { name: "exec", args: { command: "c" }, hints: READ, result: ok("") },
    { name: "exec", args: { command: "d" }, hints: READ, result: failed, durationMs: 1000 },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(
    transcriptRows(frame).filter((row) => row.startsWith(" exec")),
    [" exec · 3m 05s", " exec", " exec", " exec · error · 1s"],
  );
});

test("a silent running call counts up on its own, and its end shows the measured duration", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  ];
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  await settled();
  using clock = fixedClock();
  const execution = { eventNumber: 2, blockIndex: 0 };
  sessions.push({ sessionUpdate: "state", state: "running" });
  sessions.push({ sessionUpdate: "tool_started", execution, call });
  frame.draw();
  equal(transcriptRows(frame)[1], " exec make · running");
  clock.now += 12_000;
  frame.advance(100);
  frame.draw();
  equal(transcriptRows(frame)[1], " exec make · 12s");
  const result = { callId: "c0", content: "", isError: false };
  sessions.push({ sessionUpdate: "tool_finished", execution, result, display: [], durationMs: 40_000 });
  frame.draw();
  equal(transcriptRows(frame)[1], " exec make · 40s");
});

test("a copy of live output gives its lines", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  ];
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  const execution = { eventNumber: 2, blockIndex: 0 };
  sessions.push({ sessionUpdate: "tool_started", execution, call });
  sessions.push({ sessionUpdate: "tool_output", execution, text: "one\ntwo" });
  frame.draw();
  frame.mouse(mouse(1, 2, "press"));
  frame.mouse(mouse(4, 3, "drag"));
  frame.mouse(mouse(4, 3, "release"));
  equal(frame.copies, ["one\ntwo"]);
});

test("a folded call gives no count of the lines that its live output leaves out, and its result gives one", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  ];
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  const execution = { eventNumber: 2, blockIndex: 0 };
  sessions.push({ sessionUpdate: "tool_started", execution, call });
  sessions.push({ sessionUpdate: "tool_output", execution, text: lines("out", 8) });
  frame.draw();
  const live = transcriptRows(frame).slice(2, 8);
  const result = { callId: "c0", content: lines("out", 8), isError: false };
  sessions.push({ sessionUpdate: "tool_finished", execution, result, display: [] });
  frame.draw();
  const tail = lines(" out", 8).split("\n").slice(3);
  equal(
    [live, transcriptRows(frame).slice(2, 8)],
    [
      [" … more lines", ...tail],
      [" … 3 more lines", ...tail],
    ],
  );
});

test("a result with only media shows a label with the type, the number, and the size of each one", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const media = [
    { mime: "image/png", blob: { digest: "a".repeat(64), len: 2048 } },
    { mime: "application/pdf", blob: { digest: "b".repeat(64), len: 10 } },
  ];
  const saved = calls({ name: "probe", args: {}, hints: PROBE, result: { ...ok(""), media } });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 5), [
    "",
    " Probe",
    " [image/png #1 · 2 KiB]",
    " [application/pdf #2 · 10 B]",
    "",
  ]);
});

test("the display blocks of a result share one preview, and a diff copies its lines without numbers", async () => {
  using frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const patch = "@@ -1,2 +1,2 @@\n-old\n+new\n same\n@@ -9 +9 @@\n-c\n+d";
  const display: DisplayBlock[] = [
    { kind: "markdown", text: "**Edited**" },
    { kind: "diff", path: "src/a.rs", patch },
  ];
  const edit: ToolHints = { title: null, subject: { argument: "path", kind: "file" }, preview: "head" };
  const saved = calls({ name: "edit", args: { path: "src/a.rs" }, hints: edit, result: ok("done"), display });
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(2, 11), [
    " Edited",
    " src/a.rs",
    " 1 -old",
    " 1 +new",
    " 2  same",
    "   ⋮",
    " 9 -c",
    " 9 +d",
    "",
  ]);
  // A drag from the path to the end of the last line has no numbers, no header, no ⋮, and no blank line.
  frame.mouse(mouse(1, 3, "press"));
  frame.mouse(mouse(8, 9, "drag"));
  frame.mouse(mouse(8, 9, "release"));
  equal(frame.copies, ["src/a.rs\n-old\n+new\n same\n-c\n+d"]);
  // The source offsets of the diff rows come after the Markdown block, and the source keeps each header.
  const transcript = chat.transcript();
  const selection = transcript.selection;
  equal(
    selection === undefined ? undefined : transcript.text({ from: selection.anchor, to: selection.head }, "source"),
    `src/a.rs\n${patch}`,
  );
  // A drag from the Markdown block to the end copies both blocks with the line end between them.
  frame.mouse(mouse(1, 2, "press"));
  frame.mouse(mouse(8, 9, "drag"));
  frame.mouse(mouse(8, 9, "release"));
  equal(frame.copies.at(-1), "Edited\nsrc/a.rs\n-old\n+new\n same\n-c\n+d");
});

/** A frame with one call `edit` of `patch` at `width`, and the rows of the transcript after the head row. */
async function diffShown(patch: string, width = 40) {
  const frame = createFrame({ width, height: 24 }, undefined, { cwd: "/w", session: "s1" });
  const edit: ToolHints = { title: null, subject: { argument: "path", kind: "file" }, preview: "head" };
  const display: DisplayBlock[] = [{ kind: "diff", path: "a.rs", patch }];
  const saved = calls({ name: "edit", args: { path: "a.rs" }, hints: edit, result: ok("done"), display });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  return { frame, shown: transcriptRows(frame).slice(2) };
}

test("a diff numbers each line from its hunk header: old on a removed line, new on the others", async () => {
  const patch = "@@ -9,5 +9,2 @@\n a\n-b\n-c\n+B\n-d\n\\ No newline at end of file\n@@ -99,1 +99,2 @@\n e\n+f\n";
  const { frame, shown } = await diffShown(patch);
  using _frame = frame;

  equal(shown.slice(0, 11), [
    " a.rs",
    "   9  a",
    "  10 -b",
    "  11 -c",
    "  10 +B",
    "  12 -d",
    "     \\ No newline at end of file",
    "     ⋮",
    "  99  e",
    " 100 +f",
    "",
  ]);
});

test("a line of a hunk that starts with dashes or plus signs is a removed line or an added line", async () => {
  const { frame, shown } = await diffShown("@@ -1,3 +1,2 @@\n--- a comment\n+++b\n x\n");
  using _frame = frame;

  equal(shown.slice(1, 4), [" 1 --- a comment", " 1 +++b", " 2  x"]);
  const background = (row: number) => frame.frame.cells[row]?.[3]?.style.bg;
  assert(background(3) !== undefined && background(4) !== undefined);
  assert(background(3) !== background(4));
});

test("a wrapped line of a diff shows one number, and a copy joins its rows", async () => {
  const { frame, shown } = await diffShown("@@ -7,1 +7,1 @@\n-abcdefghijklmnop\n", 14);
  using _frame = frame;

  equal(shown.slice(1, 3), [" 7 -abcdefghi", "   jklmnop"]);
  frame.mouse(mouse(3, 3, "press"));
  frame.mouse(mouse(10, 4, "drag"));
  frame.mouse(mouse(10, 4, "release"));
  equal(frame.copies, ["-abcdefghijklmnop"]);
});

test("a drag from the ⋮ copies the next hunk without a line end before it", async () => {
  const { frame } = await diffShown("@@ -1 +1 @@\n-a\n+b\n@@ -9 +9 @@\n-c\n+d\n");
  using _frame = frame;

  frame.mouse(mouse(3, 5, "press"));
  frame.mouse(mouse(8, 7, "drag"));
  frame.mouse(mouse(8, 7, "release"));
  equal(frame.copies, ["-c\n+d"]);
});

test("a click on a subject copies its path in the folder of the call, and a click on the title opens the call", async () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls({ name: "read", args: { path: "src/main.rs" }, hints: READ, result: ok("fn main() {}") });
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  click(frame, 7, 1);
  equal([frame.copies, chat.notices], [["/tools/src/main.rs"], ["info copied /tools/src/main.rs"]]);
  equal(transcriptRows(frame).slice(0, 3), ["", " read src/main.rs", ""]);
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 4), ["", " read src/main.rs", " fn main() {}", ""]);
});

test("a click on a body row, a preview row, or the count row toggles a call, and the row between two items does not", async () => {
  using frame = createFrame({ width: 40, height: 30 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "one", args: {}, hints: PROBE, result: ok(lines("a", 12)) },
    { name: "two", args: {}, hints: PROBE, result: ok(lines("b", 12)) },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  const folded = transcriptRows(frame).slice(0, 26);
  equal(folded.slice(11, 15), [" a 10", " … 2 more lines", "", " Probe"]);
  equal(folded.slice(24, 26), [" b 10", " … 2 more lines"]);
  // A click on the row that counts the rest opens the call.
  click(frame, 3, 12);
  equal(transcriptRows(frame).slice(12, 15), [" a 11", " a 12", ""]);
  // A click on a row of the body folds it.
  click(frame, 3, 12);
  equal(transcriptRows(frame).slice(0, 26), folded);
  // The row above the second call has no toggle, so the call stays folded.
  click(frame, 3, 13);
  equal(transcriptRows(frame).slice(0, 26), folded);
  // A click on a row of a preview opens the call.
  click(frame, 3, 2);
  equal(transcriptRows(frame).slice(12, 14), [" a 11", " a 12"]);
});

test("a click on the text of an open thought folds it", async () => {
  using frame = createFrame({ width: 40, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ reasoning: { text: "why" } } as never]),
  ];
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 4), ["", " thought", " why", ""]);
  click(frame, 2, 2);
  equal(transcriptRows(frame).slice(0, 3), ["", " thought", ""]);
});

test("a call that opens at the tail stays on its rows, and the pane follows the tail again when it folds", async () => {
  using frame = createFrame({ width: 40, height: 16 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "one", args: {}, hints: PROBE, result: ok(lines("a", 3)) },
    { name: "two", args: {}, hints: PROBE, result: ok(lines("b", 40)) },
  );
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  const folded = transcriptRows(frame).slice(0, 12);
  const view = chat.transcript();
  equal(view.scroll.state.following, true);
  const more = folded.indexOf(" … 30 more lines");
  click(frame, 3, more);
  // The rows above stay, and the next rows of the output take the place of the count.
  equal(transcriptRows(frame).slice(0, more), folded.slice(0, more));
  equal(transcriptRows(frame)[more], " b 11");
  equal(view.scroll.state.following, false);
  click(frame, 3, more);
  equal(transcriptRows(frame).slice(0, 12), folded);
  equal(view.scroll.state.following, true);
  // ctrl+o keeps the pane on the tail in both directions.
  frame.key("ctrl+o");
  equal(view.scroll.state.following, true);
  frame.key("ctrl+o");
  equal(view.scroll.state.following, true);
});

test("a call that folds from a row below its hidden head line shows the head line at the top", async () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "one", args: {}, hints: PROBE, result: ok(lines("a", 3)) },
    { name: "two", args: {}, hints: PROBE, result: ok(lines("b", 40)) },
    { name: "three", args: {}, hints: PROBE, result: ok(lines("c", 3)) },
  );
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  frame.key("ctrl+o");
  chat.transcript().scroll.scrollBy(-10);
  frame.draw();
  const row = transcriptRows(frame).indexOf(" b 30");
  click(frame, 3, row);
  equal(transcriptRows(frame).slice(0, 3), [" Probe", " b 1", " b 2"]);
});

test("a call that opens in a view away from the tail leaves the rows above it in place", async () => {
  using frame = createFrame({ width: 40, height: 20 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "one", args: {}, hints: PROBE, result: ok(lines("a", 12)) },
    { name: "two", args: {}, hints: PROBE, result: ok(lines("b", 12)) },
    { name: "three", args: {}, hints: PROBE, result: ok(lines("c", 40)) },
  );
  const chat = await loadChat(frame, fakeSessions(saved));
  frame.start();
  chat.transcript().scroll.scrollTo(0);
  frame.draw();
  const before = transcriptRows(frame).slice(0, 12);
  click(frame, 3, 3);
  equal(transcriptRows(frame).slice(0, 12), before);
  equal(transcriptRows(frame)[12], " a 11");
});

test("a relative link of a call without a folder starts in the folder of the session, and one in a result in the call folder", async () => {
  using frame = createFrame({ width: 40, height: 10 }, undefined, { cwd: "/start", session: "s1" });
  const saved = calls(
    { name: "read", args: { path: "a.rs" }, hints: READ, result: ok("A"), folder: null },
    { name: "note", args: {}, hints: PROBE, result: ok("x"), display: [{ kind: "markdown", text: "[b](b.rs)" }] },
  );
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 5), ["", " read a.rs", "", " Probe", " [b](b.rs)"]);
  click(frame, 7, 1);
  click(frame, 2, 4);
  equal(frame.copies, ["/w/a.rs", "/tools/b.rs"]);
});

test("ctrl+o in the composer opens each tool when one is folded, else folds each tool, and it leaves a thought", async () => {
  using frame = createFrame({ width: 40, height: 15 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "read", args: { path: "a" }, hints: READ, result: ok("A") },
    { name: "read", args: { path: "b" }, hints: READ, result: ok("B") },
  );
  saved.push(commit(saved.length + 1, [{ reasoning: { text: "why" } } as never]));
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  // The composer has the focus, and the key reaches the command through the context of the pane.
  frame.key("ctrl+o");
  click(frame, 2, 1);
  frame.key("ctrl+o");
  equal(transcriptRows(frame).slice(0, 12), ["", " read a", " A", "", " read b", " B", "", " thought", "", "", "", ""]);
  frame.key("ctrl+o");
  equal(transcriptRows(frame).slice(0, 6), ["", " read a", "", " read b", "", " thought"]);
});

test("a link in a reply copies its target, and a relative target starts in the folder of the session", async () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/start", session: "s1" });
  const reply = "see [source](src/main.rs#L40-L52) or [docs](https://docs.rs)";
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ assistant_text: { text: reply } }]),
  ];
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  // The Markdown rows show the whole link, and each of its cells carries the target.
  equal(rows(frame.frame).slice(1, 3), [" see [source](src/main.rs#L40-L52) or", " [docs](https://docs.rs)"]);
  click(frame, 7, 1);
  click(frame, 3, 2);
  equal(frame.copies, ["/w/src/main.rs#L40-L52", "https://docs.rs"]);
});

test("a call that ended well shows a bold name, its subject in accent, dim output, and no band", async () => {
  using frame = createFrame({ width: 30, height: 24 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls({ name: "read", args: { path: "a.rs" }, hints: PROBE_FILE, result: ok(lines("row", 12)) });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  const cells = frame.frame.cells;
  const output = themeStyle("chat.tool.output");
  const subject = themeStyle("chat.subject");
  assert(subject.fg !== undefined && subject.fg !== output.fg);
  const omitted = transcriptRows(frame).findIndex((row) => row.includes("more lines"));
  equal(
    [
      cells[1]?.[1]?.style.bold,
      cells[1]?.[6]?.style.fg,
      cells[2]?.[1]?.style,
      cells[omitted]?.[3]?.style,
      cells[1]?.[28]?.style.bg,
    ],
    [true, subject.fg, output, output, undefined],
  );
});

test("a failed call has a band behind each row, and its text has the output style", async () => {
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const result = { callId: "", content: "broken", isError: true };
  await loadChat(frame, fakeSessions(calls({ name: "read", args: { path: "a.rs" }, hints: READ, result })));
  frame.start();
  const cells = frame.frame.cells;
  const band = themeStyle("chat.tool.failed").bg;
  assert(band !== undefined);
  equal(
    [
      transcriptRows(frame).slice(1, 3),
      cells[1]?.[1]?.style.bg,
      cells[1]?.[29]?.style.bg,
      cells[2]?.[0]?.style.bg,
      cells[2]?.[29]?.style.bg,
    ],
    [[" read a.rs · error", " broken"], band, band, band, band],
  );
});

test("a running call has a band until its result comes, and a copy leaves the band out", async () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  ];
  const sessions = fakeSessions(saved);
  await loadChat(frame, sessions);
  frame.start();
  using _clock = fixedClock();
  const execution = { eventNumber: 2, blockIndex: 0 };
  sessions.push({ sessionUpdate: "tool_started", execution, call });
  sessions.push({ sessionUpdate: "tool_output", execution, text: "compiling" });
  frame.draw();
  const band = themeStyle("chat.tool.pending").bg;
  assert(band !== undefined);
  const running = [1, 2].map((row) => frame.frame.cells[row]?.[29]?.style.bg);
  frame.mouse(mouse(1, 1, "press"));
  frame.mouse(mouse(29, 2, "drag"));
  frame.mouse(mouse(29, 2, "release"));
  const copied = [...frame.copies];
  const result = { callId: "c0", content: "built", isError: false };
  sessions.push({ sessionUpdate: "tool_finished", execution, result, display: [] });
  frame.draw();
  equal([running, copied, frame.frame.cells[1]?.[29]?.style], [[band, band], ["exec make · running\ncompiling"], {}]);
});

test("a diff shows an added line, a removed line, and its context in their own looks", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const display: DisplayBlock[] = [{ kind: "diff", path: "a.rs", patch: "-old\n+new\n same" }];
  const saved = calls({ name: "edit", args: { path: "a.rs" }, hints: PROBE_FILE, result: ok("done"), display });
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  const shown = transcriptRows(frame);
  const background = (text: string) => frame.frame.cells[shown.findIndex((row) => row.includes(text))]?.[2]?.style.bg;
  const removed = background("-old");
  const added = background("+new");
  assert(removed !== undefined && added !== undefined);
  assert(removed !== added);
  equal(background(" same"), undefined);
});

test("the failure of a turn shows in bold in the danger color", async () => {
  using frame = createFrame({ width: 30, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [], { end: { failed: "boom" } }),
  ];
  await loadChat(frame, fakeSessions(saved));
  frame.start();
  const row = transcriptRows(frame).findIndex((line) => line.includes("failed: boom"));
  const danger = themeStyle("chat.error").fg;
  assert(danger !== undefined);
  equal(frame.frame.cells[row]?.[1]?.style, { fg: danger, bold: true });
});
