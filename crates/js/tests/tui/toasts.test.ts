// The bundled toasts show the notices of the core as a stack at the top right.

import { apply } from "yuke:internal/bundled/toasts";
import { createFrame, equal, type FrameNotice, type FrameTest, test } from "yuke:test";
import { rows } from "./chat.ts";

/** Load the toasts into `frame`. */
function loadToasts(frame: FrameTest): void {
  const tui = frame.surface("toasts").tui;
  apply({ get: (name: string) => (name === "tui" ? tui : undefined), options: {} } as never);
}

/** Give the toast part of each row of `frame`. The part starts at `column`, and the test trims it. */
function stack(frame: FrameTest, column = 25): string[] {
  return rows(frame)
    .map((row) => row.slice(column).trim())
    .filter((row) => row !== "");
}

const notice = (level: FrameNotice["level"], source: string, text: string, sessionId?: string): FrameNotice => ({
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
  const bar = frame.frame.cells[1]?.[25];
  frame.advance(3999);
  const before = stack(frame);
  frame.advance(1);
  equal(
    [shown, bar?.style, before, stack(frame)],
    [["▌ lint", "▌ all clean"], { fg: "#a8cfa0", bg: "#343a46" }, ["▌ lint", "▌ all clean"], []],
  );
});

test("a warning and an error stay, and debug shows no toast", () => {
  using frame = createFrame({ width: 50, height: 10 });
  loadToasts(frame);
  frame.notice(notice("debug", "console", "trace"));
  frame.notice(notice("warn", "lint", "3 errors"));
  frame.notice(notice("error", "host:session", "the turn failed"));
  frame.advance(60_000);
  equal(stack(frame), ["▌ lint", "▌ 3 errors", "▌ host:session", "▌ the turn failed"]);
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
  equal(
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
  equal(
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
  const press = (button: "left" | "right"): void =>
    frame.mouse({
      type: "mouse",
      button,
      action: "press",
      column: 30,
      row: 4,
      modifiers: { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false },
    });
  press("right");
  const right = stack(frame).length;
  press("left");
  const clicked = stack(frame);
  frame.key("ctrl+l");
  equal([right, clicked, stack(frame)], [4, ["▌ first", "▌ a"], []]);
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
  const listed = rows(frame).filter((row) => /^(info|error) /.test(row));
  equal(
    [shown, listed],
    [
      ["▌ plugin ×2", "▌ did not load"],
      ["info late: bye", "error plugin ×2: did not load", "info early: hello"],
    ],
  );
});
