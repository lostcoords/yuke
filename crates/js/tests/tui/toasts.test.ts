// The bundled toasts show the notices of the core as a stack at the top right.

import { apply } from "yuke:internal/bundled/toasts";
import type { NoticeParams } from "yuke:protocol";
import { assert, assertEquals, createFrame, type FrameTest, test } from "yuke:test";
import { mouse } from "./chat.ts";
import { rows } from "./rows.ts";

/** Load the toasts into `frame`. */
function loadToasts(frame: FrameTest): void {
  const tui = frame.surface("toasts").tui;
  apply({ get: (name: string) => (name === "tui" ? tui : undefined), options: {} } as never);
}

/** Give the toast part of each row of `frame`. The part starts at `column`, and the test trims it. */
function stack(frame: FrameTest, column = 25): string[] {
  return rows(frame.frame)
    .map((row) => row.slice(column).trim())
    .filter((row) => row !== "");
}

const notice = (level: NoticeParams["level"], source: string, text: string, sessionId?: string): NoticeParams => ({
  level,
  source,
  text,
  ...(sessionId === undefined ? {} : { sessionId }),
});

test("an info toast shows at the top right with its level bar and leaves after 4 s", () => {
  using frame = createFrame({ width: 50, height: 8 });
  loadToasts(frame);
  frame.notice(notice("info", "lint", "all clean"));
  const shown = stack(frame);
  frame.advance(3999);
  const before = stack(frame);
  frame.advance(1);
  assertEquals([shown, before, stack(frame)], [["▌ lint", "▌ all clean"], ["▌ lint", "▌ all clean"], []]);
});

test("a warning and an error stay, and debug shows no toast", () => {
  using frame = createFrame({ width: 50, height: 10 });
  loadToasts(frame);
  frame.notice(notice("debug", "console", "trace"));
  frame.notice(notice("warn", "lint", "3 errors"));
  frame.notice(notice("error", "host:session", "the turn failed"));
  frame.advance(60_000);
  assertEquals(stack(frame), ["▌ lint", "▌ 3 errors", "▌ session", "▌ the turn failed"]);
});

test("an equal notice raises the count of its toast and starts its wait again, also with others between", () => {
  using frame = createFrame({ width: 50, height: 12 });
  loadToasts(frame);
  frame.notice(notice("info", "lint", "all clean"));
  frame.advance(3000);
  frame.notice(notice("warn", "other", "between"));
  frame.notice(notice("info", "lint", "all clean"));
  frame.advance(3000);
  const merged = stack(frame);
  frame.notice(notice("warn", "lint", "3 errors", "a"));
  frame.notice(notice("warn", "lint", "3 errors", "b"));
  assertEquals(
    [merged, stack(frame).filter((row) => row.startsWith("▌ lint"))],
    [
      ["▌ lint ×2", "▌ all clean", "▌ other", "▌ between"],
      ["▌ lint ×2", "▌ lint", "▌ lint"],
    ],
  );
});

test("a full stack drops its oldest info toast, else its oldest toast", () => {
  using frame = createFrame({ width: 50, height: 20 });
  loadToasts(frame);
  frame.notice(notice("warn", "w1", "a"));
  frame.notice(notice("info", "i1", "b"));
  frame.notice(notice("warn", "w2", "c"));
  frame.notice(notice("warn", "w3", "d"));
  frame.notice(notice("error", "e1", "e"));
  const titles = (): string[] => stack(frame).filter((_, at) => at % 2 === 0);
  const first = titles();
  frame.notice(notice("error", "e2", "f"));
  assertEquals(
    [first, titles()],
    [
      ["▌ w1", "▌ w2", "▌ w3", "▌ e1"],
      ["▌ w2", "▌ w3", "▌ e1", "▌ e2"],
    ],
  );
});

test("a click dismisses its toast and ctrl+l dismisses all", () => {
  using frame = createFrame({ width: 50, height: 10 });
  loadToasts(frame);
  frame.notice(notice("warn", "first", "a"));
  frame.notice(notice("warn", "second", "b"));
  const press = (button: "left" | "right"): void => frame.mouse({ ...mouse(30, 4, "press"), button });
  press("right");
  const right = stack(frame).length;
  press("left");
  const clicked = stack(frame);
  frame.key("ctrl+l");
  assertEquals([right, clicked, stack(frame)], [4, ["▌ first", "▌ a"], []]);
});

test("the history shows a source from yuke without host:", () => {
  using frame = createFrame({ width: 50, height: 10 });
  loadToasts(frame);
  frame.notice(notice("error", "host:session", "the turn failed"));
  frame.surface("demo").tui.commands.run("toasts:history");
  frame.draw();

  assertEquals(
    rows(frame.frame).filter((row) => row.startsWith("error ")),
    ["error session: the turn failed"],
  );
});

test("the warnings and errors before the load show, and the history lists each notice, the newest first", () => {
  using frame = createFrame({ width: 50, height: 10 });
  frame.notice(notice("info", "early", "hello"));
  frame.notice(notice("error", "plugin", "did not load"));
  frame.notice(notice("error", "plugin", "did not load"));
  loadToasts(frame);
  frame.draw();
  const shown = stack(frame);
  frame.notice(notice("info", "late", "bye"));
  frame.surface("demo").tui.commands.run("toasts:history");
  frame.draw();
  const listed = rows(frame.frame).filter((row) => /^(info|error) /.test(row));
  assertEquals(
    [shown, listed],
    [
      ["▌ plugin ×2", "▌ did not load"],
      ["info late: bye", "error plugin ×2: did not load", "info early: hello"],
    ],
  );
});

test("a toast has a default look per level that a plugin changes", () => {
  using frame = createFrame({ width: 50, height: 12 });
  loadToasts(frame);
  frame.notice(notice("error", "lint", "failed"));
  frame.notice(notice("warn", "lint", "careful"));
  const looks = () => {
    const cells = frame.draw().cells;
    return [cells[1]?.[25], cells[1]?.[27], cells[2]?.[27], cells[1]?.[45], cells[4]?.[27], cells[4]?.[25]].map(
      (cell) => cell?.style,
    );
  };
  const before = looks();
  frame.surface("theme").tui.styles.add({
    "toast.body": { fg: 1, bg: 2 },
    "toast.error": { fg: 3 },
    "toast.warn": { fg: 4 },
    "toast.title": { bold: null, italic: true },
  });
  // The level sets the color of the bar, and the body has a background.
  assert(before[0]?.fg !== undefined && before[5]?.fg !== undefined && before[2]?.bg !== undefined);
  assertEquals(
    [before[0]?.fg !== before[5]?.fg, looks()],
    [
      true,
      [
        { fg: 3, bg: 2 },
        { fg: 3, bg: 2, italic: true },
        { fg: 1, bg: 2 },
        { fg: 1, bg: 2 },
        { fg: 4, bg: 2, italic: true },
        { fg: 4, bg: 2 },
      ],
    ],
  );
});
