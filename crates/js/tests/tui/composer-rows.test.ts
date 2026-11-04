// Rows of plugins on each side of the composer of the bundled chat: their place, their limit, and their order.

import type { ComposerRowsContext } from "yuke:chat";
import type { SessionUpdate } from "yuke:protocol";
import { createFrame, equal, settled, test } from "yuke:test";
import { fakeSessions, loadChat } from "./chat.ts";
import { rows } from "./rows.ts";

/** The update that accepts the waiting message `text` of the user as the input `id`. */
function waiting(id: number, text: string): SessionUpdate {
  return {
    sessionUpdate: "input_accepted",
    inputId: id,
    input: { source: { kind: "user" }, kind: "message", content: [{ user_text: text }] },
  };
}

test("plugin rows show below the transcript and above the waiting messages, cut to the width, in add order", async () => {
  using frame = createFrame({ width: 24, height: 11 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  const seen: ComposerRowsContext[] = [];
  chat.chat.addComposerRows("above", (pane) => {
    seen.push(pane);
    return [{ text: "first source, a longer row", style: { bold: true } }, { text: "its second row" }];
  });
  const remove = chat.chat.addComposerRows("above", () => [{ text: "second source" }]);
  frame.start();
  await settled();
  sessions.push(waiting(5, "fix the test"));
  frame.draw();
  const shown = rows(frame.frame).slice(3);
  const bold = frame.frame.cells[4]?.[0]?.style.bold;
  remove();
  frame.draw();
  equal(
    [shown, bold, rows(frame.frame).slice(5, 8), seen.at(-1)],
    [
      [
        "",
        "first source, a longer …",
        "its second row",
        "second source",
        " fix the test     ↑ edit",
        "────────────────────────",
        "Message…",
        "────────────────────────",
      ],
      true,
      ["first source, a longer …", "its second row", " fix the test     ↑ edit"],
      { session: "s1", width: 24, composer: chat.tui.focused },
    ],
  );
});

test("plugin rows take at most half the rows above the rule and give way to the strip, and a source shows whole", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  const three = ["a1", "a2", "a3"].map((text) => ({ text }));
  chat.chat.addComposerRows("above", () => three);
  chat.chat.addComposerRows("above", () => [{ text: "b1" }, { text: "b2" }, { text: "b3" }]);
  chat.chat.addComposerRows("above", () => [{ text: "c1" }]);
  frame.start();
  await settled();
  /** The plugin rows on the screen. */
  const plugin = (): string[] => {
    frame.draw();
    return rows(frame.frame).filter((text) => /^[abc]\d$/.test(text));
  };
  // Nine rows above the rule give plugins four. The three rows of the second source do not fit, so the chat hides it
  // and the later sources.
  const half = plugin();
  for (let id = 1; id <= 8; id++) sessions.push(waiting(id, `m${id}`));
  equal([half, plugin()], [["a1", "a2", "a3"], []]);
});

test("rows below show under the composer, cut to the width, in add order, and the composer moves up", async () => {
  using frame = createFrame({ width: 24, height: 11 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  const seen: ComposerRowsContext[] = [];
  chat.chat.addComposerRows("below", (pane) => {
    seen.push(pane);
    return [{ text: "first source, a longer row", style: { bold: true } }, { text: "its second row" }];
  });
  const remove = chat.chat.addComposerRows("below", () => [{ text: "second source" }]);
  chat.chat.addComposerRows("above", () => [{ text: "above" }]);
  frame.start();
  await settled();
  frame.draw();
  const shown = rows(frame.frame).slice(4);
  const bold = frame.frame.cells[8]?.[0]?.style.bold;
  remove();
  frame.draw();
  const rule = "─".repeat(24);
  equal(
    [shown, bold, rows(frame.frame).slice(5), seen.at(-1)],
    [
      ["above", rule, "Message…", rule, "first source, a longer …", "its second row", "second source"],
      true,
      ["above", rule, "Message…", rule, "first source, a longer …", "its second row"],
      { session: "s1", width: 24, composer: chat.tui.focused },
    ],
  );
});

test("rows below take at most half the pane, a source shows whole, and the first that does not fit hides the later", async () => {
  using frame = createFrame({ width: 24, height: 13 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  const row = (text: string) => ({ text });
  chat.chat.addComposerRows("below", () => ["a1", "a2", "a3", "a4"].map(row));
  chat.chat.addComposerRows("below", () => ["b1", "b2", "b3"].map(row));
  chat.chat.addComposerRows("below", () => ["c1"].map(row));
  // The rows of the other place do not count against this place.
  chat.chat.addComposerRows("above", () => ["d1", "d2", "d3"].map(row));
  frame.start();
  await settled();
  frame.draw();

  equal(
    rows(frame.frame).filter((text) => /^[abcd]\d$/.test(text)),
    ["d1", "d2", "d3", "a1", "a2", "a3", "a4"],
  );
});

test("rows below leave the composer half of the rows that remain", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerRows("below", () => ["b1", "b2", "b3", "b4"].map((text) => ({ text })));
  frame.start();
  await settled();
  frame.paste("1\n2\n3\n4\n5\n6\n7\n8\n9");
  frame.draw();
  const shown = rows(frame.frame);

  equal([shown.findIndex((line) => line.startsWith("──")), shown.slice(-4)], [3, ["b1", "b2", "b3", "b4"]]);
});

test("a pane of two rows shows a row below and the composer, and no rule", async () => {
  using frame = createFrame({ width: 24, height: 2 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerRows("below", () => [{ text: "only" }]);
  frame.start();
  await settled();
  frame.draw();

  equal(rows(frame.frame), ["Message…", "only"]);
});

test("each add is its own source, so the same source shows twice and a disposer removes only its own", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  const source = () => [{ text: "same" }];
  const first = chat.chat.addComposerRows("above", source);
  chat.chat.addComposerRows("above", source);
  frame.start();
  await settled();
  /** The count of rows of the source. */
  const count = (): number => {
    frame.draw();
    return rows(frame.frame).filter((text) => text === "same").length;
  };
  const both = count();
  first();
  first();
  equal([both, count()], [2, 1]);
});

test("the rule above the composer has a default look that a plugin changes", async () => {
  using frame = createFrame({ width: 24, height: 6 }, undefined, { cwd: "/w" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await settled();
  const look = () => {
    const cells = frame.draw().cells;
    return cells[rows(frame.frame).findIndex((line) => line.startsWith("──"))]?.[0]?.style;
  };
  const before = look();
  frame.surface("theme").tui.styles.set({ "chat.rule": { fg: 1, dim: null } });
  equal([before, look()], [{ dim: true }, { fg: 1 }]);
});

test("a pane without plugin rows shows a rule below the composer, in the look of the rule above it", async () => {
  using frame = createFrame({ width: 24, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await settled();
  frame.draw();
  const rule = "─".repeat(24);
  equal([rows(frame.frame), frame.frame.cells[5]?.[23]?.style], [["", "", "", rule, "Message…", rule], { dim: true }]);
});

test("plugin rows below sit under the rule below the composer, and the composer moves up by the rule and the rows", async () => {
  using frame = createFrame({ width: 24, height: 8 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerRows("below", () => [{ text: "first" }, { text: "second" }]);
  frame.start();
  await settled();
  frame.draw();
  const rule = "─".repeat(24);
  equal(rows(frame.frame), ["", "", "", rule, "Message…", rule, "first", "second"]);
});

test("a pane with two free rows has no rule below the composer, and a pane with three free rows has both rules", async () => {
  using frame = createFrame({ width: 24, height: 2 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await settled();
  frame.draw();
  const two = rows(frame.frame);
  frame.resize({ width: 24, height: 3 });
  const rule = "─".repeat(24);
  equal(
    [two, rows(frame.frame)],
    [
      [rule, "Message…"],
      [rule, "Message…", rule],
    ],
  );
});

test("a plugin row below takes a free row from the rule below the composer", async () => {
  using frame = createFrame({ width: 24, height: 3 }, undefined, { cwd: "/w", session: "s1" });
  const chat = await loadChat(frame, fakeSessions());
  chat.chat.addComposerRows("below", () => [{ text: "only" }]);
  frame.start();
  await settled();
  frame.draw();
  const two = rows(frame.frame);
  frame.resize({ width: 24, height: 4 });
  const rule = "─".repeat(24);
  equal(
    [two, rows(frame.frame)],
    [
      [rule, "Message…", "only"],
      [rule, "Message…", rule, "only"],
    ],
  );
});

test("a tall draft stays above the rule below the composer, with the caret on its last line", async () => {
  using frame = createFrame({ width: 24, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  await loadChat(frame, fakeSessions());
  frame.start();
  await settled();
  frame.paste("1\n2\n3\n4\n5\n6\n7\n8\n9");
  frame.draw();
  const rule = "─".repeat(24);
  equal(
    [rows(frame.frame), frame.frame.cursor],
    [["", "", "", "", "", rule, "5", "6", "7", "8", "9", rule], { column: 1, row: 10 }],
  );
});

test("a tall question stays above the rule below the composer, with the caret on its field", async () => {
  using frame = createFrame({ width: 40, height: 12 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  await loadChat(frame, sessions);
  frame.start();
  await settled();
  const question = Array.from({ length: 10 }, (_, index) => `line ${index + 1}`).join("\n");
  const options = [{ label: "Yes" }];
  sessions.push({
    sessionUpdate: "interaction_requested",
    interactionId: 1,
    source: "guard",
    request: { kind: "questions", questions: [{ id: "q", header: "Q", question, options, other: true }] },
  });
  frame.key("down");
  frame.draw();
  const rule = "─".repeat(40);
  equal(
    [rows(frame.frame).slice(5), frame.frame.cursor],
    [
      [rule, " guard · Q", " line 1", "  Yes", "❯ Type your own answer…", " ↑↓ choose · enter send · esc cancel", rule],
      { column: 2, row: 9 },
    ],
  );
});
