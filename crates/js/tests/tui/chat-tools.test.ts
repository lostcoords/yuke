// The tool calls of the bundled chat: the head line, the previews, the body, the diffs, the folds, and the links.

import type { Block, DisplayBlock, StoredEvent, ToolHints, ToolResult } from "yuke:protocol";
import { createFrame, equal, test } from "yuke:test";
import { click, commit, fakeSessions, loadChat, mouse, rows, SETTINGS, transcriptRows } from "./chat.ts";

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
    const shown = call.display === undefined ? [] : [{ blockIndex: 0, blocks: call.display }];
    saved.push(commit(saved.length + 1, [result], { display: { calls: [], results: shown } }));
  }
  return saved;
}

const READ: ToolHints = { title: null, subject: { argument: "path", kind: "file" }, preview: "none" };
const EXEC: ToolHints = { title: null, subject: { argument: "command", kind: "text" }, preview: "tail" };
const PROBE: ToolHints = { title: "Probe", subject: null, preview: "head" };

const ok = (content: string): ToolResult => ({ callId: "", content, isError: false });

test("a folded call shows the head line and the preview of its hints, and an error shows its first rows", () => {
  using frame = createFrame({ width: 30, height: 40 }, undefined, { cwd: "/w", session: "s1" });
  const long = "x".repeat(50);
  const saved = calls(
    { name: "read", args: { path: "src/main.rs" }, hints: READ, result: ok(lines("line", 30)) },
    { name: "exec", args: { command: "npm test" }, hints: EXEC, result: ok(`${lines("out", 4)}\n${long}`) },
    { name: "probe", args: {}, hints: PROBE, result: ok(lines("row", 12)) },
    { name: "fail", args: {}, hints: READ, result: { callId: "", content: lines("err", 11), isError: true } },
  );
  loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 37), [
    "",
    " read src/main.rs",
    "",
    " exec npm test",
    // The long line wraps at 28 cells, so its two rows count in the tail.
    " … 1 more rows",
    " out 2",
    " out 3",
    " out 4",
    ` ${"x".repeat(28)}`,
    ` ${"x".repeat(22)}`,
    "",
    " Probe",
    ...lines(" row", 10).split("\n"),
    " … 2 more rows",
    "",
    " fail · error",
    ...lines(" err", 10).split("\n"),
    " … 1 more rows",
    "",
  ]);
});

test("the live output of a call gives way to its result at once", () => {
  using frame = createFrame({ width: 30, height: 10 }, undefined, { cwd: "/w", session: "s1" });
  const call = { callId: "c0", name: "exec", arguments: '{"command":"make"}' };
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ tool_call: call }], {
      display: { calls: [{ blockIndex: 0, hints: EXEC, folder: "/w" }], results: [] },
    }),
  ];
  const sessions = fakeSessions(saved);
  loadChat(frame, {}, sessions);
  frame.start();
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

test("the display blocks of a result share one preview, and a diff keeps its styles and its text in a copy", () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const patch = "@@ -1 +1 @@\n-old\n+new\n same";
  const display: DisplayBlock[] = [
    { kind: "markdown", text: "**Edited**" },
    { kind: "diff", path: "src/a.rs", patch },
  ];
  const edit: ToolHints = { title: null, subject: { argument: "path", kind: "file" }, preview: "head" };
  const saved = calls({ name: "edit", args: { path: "src/a.rs" }, hints: edit, result: ok("done"), display });
  const chat = loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  const shown = transcriptRows(frame);
  equal(shown.slice(0, 9), [
    "",
    " edit src/a.rs",
    " Edited",
    " src/a.rs",
    " @@ -1 +1 @@",
    " -old",
    " +new",
    "  same",
    "",
  ]);
  const background = (row: number) => frame.frame.cells[row]?.[2]?.style.bg;
  equal([background(6), background(5)], ["#20372a", "#3a2426"]);
  // A drag from the path to the end of the last line copies the diff block as its source.
  frame.mouse(mouse(1, 3, "press"));
  frame.mouse(mouse(6, 7, "drag"));
  frame.mouse(mouse(6, 7, "release"));
  equal(frame.copies, [`src/a.rs\n${patch}`]);
  // The source offsets of the diff rows come after the Markdown block in the source of the result.
  const transcript = chat.transcript();
  const selection = transcript.selection;
  equal(
    selection === undefined ? undefined : transcript.text({ from: selection.anchor, to: selection.head }, "source"),
    `src/a.rs\n${patch}`,
  );
  // A drag from the Markdown block to the end copies both blocks with the line end between them.
  frame.mouse(mouse(1, 2, "press"));
  frame.mouse(mouse(6, 7, "drag"));
  frame.mouse(mouse(6, 7, "release"));
  equal(frame.copies, [`src/a.rs\n${patch}`, `Edited\nsrc/a.rs\n${patch}`]);
});

test("a click on a subject copies its path in the folder of the call, and a click on the title opens the call", () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls({ name: "read", args: { path: "src/main.rs" }, hints: READ, result: ok("fn main() {}") });
  const chat = loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  click(frame, 7, 1);
  equal([frame.copies, chat.notices], [["/tools/src/main.rs"], ["info copied /tools/src/main.rs"]]);
  equal(transcriptRows(frame).slice(0, 3), ["", " read src/main.rs", ""]);
  click(frame, 2, 1);
  equal(transcriptRows(frame).slice(0, 5), ["", " read src/main.rs", ' {"path":"src/main.rs"}', " fn main() {}", ""]);
});

test("a relative link of a call without a folder starts in the folder of the session, and one in a result in the call folder", () => {
  using frame = createFrame({ width: 40, height: 10 }, undefined, { cwd: "/start", session: "s1" });
  const saved = calls(
    { name: "read", args: { path: "a.rs" }, hints: READ, result: ok("A"), folder: null },
    { name: "note", args: {}, hints: PROBE, result: ok("x"), display: [{ kind: "markdown", text: "[b](b.rs)" }] },
  );
  loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  equal(transcriptRows(frame).slice(0, 5), ["", " read a.rs", "", " Probe", " [b](b.rs)"]);
  click(frame, 7, 1);
  click(frame, 2, 4);
  equal(frame.copies, ["/w/a.rs", "/tools/b.rs"]);
});

test("ctrl+o in the composer opens each tool when one is folded, else folds each tool, and it leaves a thought", () => {
  using frame = createFrame({ width: 40, height: 14 }, undefined, { cwd: "/w", session: "s1" });
  const saved = calls(
    { name: "read", args: { path: "a" }, hints: READ, result: ok("A") },
    { name: "read", args: { path: "b" }, hints: READ, result: ok("B") },
  );
  saved.push(commit(saved.length + 1, [{ reasoning: { text: "why" } } as never]));
  loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  // The composer has the focus, and the key reaches the command through the context of the pane.
  frame.key("ctrl+o");
  click(frame, 2, 1);
  frame.key("ctrl+o");
  equal(transcriptRows(frame).slice(0, 12), [
    "",
    " read a",
    ' {"path":"a"}',
    " A",
    "",
    " read b",
    ' {"path":"b"}',
    " B",
    "",
    " thought",
    "",
    "",
  ]);
  frame.key("ctrl+o");
  equal(transcriptRows(frame).slice(0, 6), ["", " read a", "", " read b", "", " thought"]);
});

test("a link in a reply copies its target, and a relative target starts in the folder of the session", () => {
  using frame = createFrame({ width: 40, height: 8 }, undefined, { cwd: "/start", session: "s1" });
  const reply = "see [source](src/main.rs#L40-L52) or [docs](https://docs.rs)";
  const saved: StoredEvent[] = [
    { seq: 1, sessionUpdate: "settings", ...SETTINGS },
    commit(2, [{ assistant_text: reply }]),
  ];
  loadChat(frame, {}, fakeSessions(saved));
  frame.start();
  // The Markdown rows show the whole link, and each of its cells carries the target.
  equal(rows(frame).slice(1, 3), [" see [source](src/main.rs#L40-L52) or", " [docs](https://docs.rs)"]);
  click(frame, 7, 1);
  click(frame, 3, 2);
  equal(frame.copies, ["/w/src/main.rs#L40-L52", "https://docs.rs"]);
});
