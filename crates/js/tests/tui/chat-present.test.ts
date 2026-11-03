// The look of the transcript from a plugin: `chat.present`, with one row that groups all tools.

import { ChatDocument, type ChatPresentation, type ChatPresentationOptions } from "yuke:chat";
import type { StoredEvent } from "yuke:protocol";
import { createFrame, equal, settled, test } from "yuke:test";
import type { Transcript } from "yuke:transcript";
import type { TextDocument, View } from "yuke:tui";
import { click, commit, fakeSessions, loadChat, SETTINGS, transcriptRows } from "./chat.ts";

const GROUP = "group";

/** One row for all tools of a transcript. An open row has the default rows of the tools after it. */
class Grouped implements ChatPresentation {
  readonly #key: string;
  readonly #inner: ChatDocument;
  readonly #folds: Map<string, boolean>;
  label = "tools";

  constructor(options: ChatPresentationOptions) {
    this.#key = options.key;
    this.#inner = new ChatDocument(options.key);
    this.#folds = new Map(options.folds);
  }

  get folds(): [string, boolean][] {
    return [...this.#folds];
  }

  toggle(_transcript: Transcript, key: string): boolean {
    if (key !== GROUP) return false;
    this.#folds.set(GROUP, this.#folds.get(GROUP) !== true);
    return true;
  }

  toggleTools(transcript: Transcript): void {
    this.toggle(transcript, GROUP);
  }

  project(transcript: Transcript): TextDocument {
    const tools = new Set(transcript.entries.filter((entry) => entry.kind === "tool").map((entry) => entry.key));
    const items = this.#inner.project(transcript).items;
    // The section has no title, so an open or a fold must not depend on that name.
    const text = `● ${this.label}: ${tools.size}`;
    const row = { key: GROUP, sections: [{ key: "summary", kind: "label" as const, text }] };
    const open = this.#folds.get(GROUP) === true ? items.filter((item) => tools.has(item.key)) : [];
    return { key: this.#key, items: [...items.filter((item) => !tools.has(item.key)), row, ...open] };
  }
}

/** A session with one read call and its result for each of `paths`. */
function reads(...paths: string[]): StoredEvent[] {
  const hints = { title: null, subject: { argument: "path", kind: "file" as const }, preview: "none" as const };
  const saved: StoredEvent[] = [{ seq: 1, sessionUpdate: "settings", ...SETTINGS }];
  for (const [at, path] of paths.entries()) {
    const callId = `c${at}`;
    const call = { tool_call: { callId, name: "read", arguments: JSON.stringify({ path }) } };
    const display = { calls: [{ blockIndex: 0, hints, folder: "/w" }], results: [] };
    saved.push(commit(saved.length + 1, [call], { display }));
    const result = { tool_result: { callId, content: "text", isError: false } };
    saved.push(commit(saved.length + 1, [result], { display: { calls: [], results: [] } }));
  }
  return saved;
}

/** The rows of the transcript of `frame` that have text. */
function shown(frame: Parameters<typeof transcriptRows>[0]): string[] {
  return transcriptRows(frame).filter((row) => row !== "");
}

test("a plugin shows three tools as one row, and a click opens and folds that row", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(reads("a", "b", "c")));
  chat.chat.present((options) => new Grouped(options));
  frame.start();
  await settled();
  frame.draw();
  const folded = shown(frame);
  click(frame, 1, transcriptRows(frame).indexOf("● tools: 3"));
  const opened = shown(frame);
  click(frame, 1, transcriptRows(frame).indexOf("● tools: 3"));
  equal(
    [folded, opened, shown(frame)],
    [["● tools: 3"], ["● tools: 3", " read a", " read b", " read c"], ["● tools: 3"]],
  );
});

test("a plugin that loads after the pane mounts changes the open pane and keeps its folds, and its disposer gives the default look back", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(reads("a", "b")));
  frame.start();
  await settled();
  frame.draw();
  click(frame, 1, transcriptRows(frame).indexOf(" read a"));
  const before = shown(frame);
  const remove = chat.chat.present((options) => new Grouped(options));
  frame.draw();
  const present = shown(frame);
  remove();
  frame.draw();
  equal(
    [before, present, shown(frame)],
    [[" read a", " text", " read b"], ["● tools: 2"], [" read a", " text", " read b"]],
  );
});

test("a disposer of an old factory leaves the look of a later factory", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(reads("a")));
  const removeOld = chat.chat.present(() => new ChatDocument("old"));
  chat.chat.present((options) => new Grouped(options));
  removeOld();
  frame.start();
  await settled();
  frame.draw();
  equal(shown(frame), ["● tools: 1"]);
});

test("changed shows new state of a presentation with no session event, and a frame alone does not", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(reads("a")));
  let grouped: Grouped | undefined;
  let changed = (): void => {};
  chat.chat.present((options) => {
    grouped = new Grouped(options);
    changed = options.changed;
    return grouped;
  });
  frame.start();
  await settled();
  frame.draw();
  (grouped as unknown as Grouped).label = "running";
  chat.tui.requestFrame();
  frame.draw();
  const framed = shown(frame);
  changed();
  frame.draw();
  equal([framed, shown(frame)], [["● tools: 1"], ["● running: 1"]]);
});

test("a session change, a new factory, and a pane close abort the signal, and each presentation gets the key of its session", async () => {
  using frame = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions(reads("a")));
  const options: ChatPresentationOptions[] = [];
  const factory = (given: ChatPresentationOptions): ChatPresentation => {
    options.push(given);
    return new Grouped(given);
  };
  chat.chat.present(factory);
  frame.start();
  await settled();
  const pane = chat.tui.panes.active?.view as View;
  await chat.chat.show("s2");
  const afterShow = [options[0]?.signal.aborted, options[1]?.signal.aborted];
  chat.chat.present((given) => factory(given));
  frame.draw();
  const afterFactory = [options[1]?.signal.aborted, options[2]?.signal.aborted];
  chat.tui.commands.run("core:split-right");
  frame.draw();
  chat.tui.commands.run("core:close");
  frame.draw();
  equal(
    [
      options.map((given) => given.key),
      afterShow,
      afterFactory,
      options[3]?.signal.aborted,
      options[2]?.signal.aborted,
      chat.chat.session(pane),
    ],
    [["session:s1", "session:s2", "session:s2", "session:new"], [true, false], [true, false], true, false, "s2"],
  );
});

test("a group key in the folds survives a snapshot and a restore", async () => {
  using before = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const first = await loadChat(before, fakeSessions(reads("a")));
  first.chat.present((options) => new Grouped(options));
  before.start();
  await settled();
  before.draw();
  click(before, 1, transcriptRows(before).indexOf("● tools: 1"));
  const snapshot = before.snapshot();
  using after = createFrame({ width: 30, height: 12 }, undefined, { cwd: "/w" });
  const second = await loadChat(after, fakeSessions(reads("a")));
  second.chat.present((options) => new Grouped(options));
  after.start(snapshot);
  await settled();
  after.draw();
  equal(shown(after), ["● tools: 1", " read a"]);
});
