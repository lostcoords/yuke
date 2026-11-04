import { createFrame, equal, settled, test } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { fakeSessions, loadChat } from "./chat.ts";

test("a fresh chat replaces only the active pane and discards its draft", async () => {
  using frame = createFrame({ width: 40, height: 8 });
  const chat = await loadChat(frame);
  frame.start();
  frame.paste("keep this");
  chat.tui.commands.run("core:split-right");
  frame.paste("discard this");
  chat.chat.newChat();
  frame.draw();
  const editors = chat.tui.widgets
    .list()
    .map((mount) => mount.widget)
    .filter((widget) => widget instanceof TextEditor);
  equal(
    editors.map((editor) => editor.state.text),
    ["keep this", ""],
  );
  frame.paste("fresh");
  equal(
    editors.map((editor) => editor.state.text),
    ["keep this", "fresh"],
  );
});

test("a custom model picker applies to the first send and a one-call picker keeps the registered picker", async () => {
  using frame = createFrame({ width: 40, height: 8 });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  let calls = 0;
  chat.chat.setModelPicker(async () => {
    calls += 1;
    return { model: { provider: "p", model: "m" }, reasoning: "high" };
  });
  await chat.chat.chooseModel(async () => ({ model: { provider: "p", model: "n" }, reasoning: "low" }));
  frame.paste("hello");
  frame.key("enter");
  await settled();
  equal(
    sessions.created.map((settings) => [settings.model, settings.settings.reasoning]),
    [
      [
        { provider: "p", model: "n" },
        { thinking: null, effort: "low" },
      ],
    ],
  );
  await chat.chat.chooseModel();
  equal([calls, sessions.changes.at(-1)?.model], [1, { provider: "p", model: "m" }]);
});

test("a cancelled or invalid custom model choice preserves the draft and creates no session", async () => {
  using frame = createFrame({ width: 40, height: 8 });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  frame.paste("keep draft");
  await chat.chat.chooseModel(async () => undefined);
  await chat.chat.chooseModel(async () => ({ model: { provider: "p", model: "missing" }, reasoning: "high" }));
  const editor = chat.tui.focused;
  equal([editor instanceof TextEditor && editor.state.text, sessions.created.length], ["keep draft", 0]);
  equal(
    chat.notices.some((notice) => notice.includes("not in the ready catalog")),
    true,
  );
});

test("an empty view stays below notices, keeps composer focus, and stops when its registration ends", async () => {
  using frame = createFrame({ width: 60, height: 18 });
  const loaded = await loadChat(frame);
  let created = 0;
  let lifetime: AbortSignal | undefined;
  const stop = loaded.chat.setEmptyView((context) => {
    created += 1;
    lifetime = context.signal;
    return { draw: (canvas) => canvas.text(1, 1, "Welcome dashboard") };
  });
  frame.start();
  frame.draw();
  equal(
    frame.frame.cells[1]
      ?.map((cell) => cell.text)
      .join("")
      .includes("Welcome dashboard"),
    true,
  );
  equal(loaded.tui.focused instanceof TextEditor, true);
  const notice = loaded.tui.overlay(() => ({ draw: (canvas) => canvas.text(0, 0, "Visible notice") }), {
    modal: false,
    place: () => ({ column: 1, row: 1, width: 20, height: 1 }),
  });
  frame.draw();
  equal(
    frame.frame.cells[1]
      ?.map((cell) => cell.text)
      .join("")
      .includes("Visible notice"),
    true,
  );
  notice.close();
  frame.paste("draft");
  equal(
    frame.frame.cells
      .flat()
      .map((cell) => cell.text)
      .join("")
      .includes("Welcome dashboard"),
    false,
  );
  stop();
  equal(lifetime?.aborted, true);
  for (let index = 0; index < 5; index += 1) frame.key("backspace");
  equal(
    frame.frame.cells
      .flat()
      .map((cell) => cell.text)
      .join("")
      .includes("Welcome dashboard"),
    false,
  );
  equal(created, 1);
});
