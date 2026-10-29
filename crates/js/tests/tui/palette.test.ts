// The command palette of the core shows the enabled commands, runs a choice, and cancels. The surface checks its input.

import { createFrame, equal, test, throws } from "yuke:test";
import { TextEditor, type View } from "yuke:tui";
import { rows } from "./chat.ts";

/** A root view that places `editor` on its last row. */
function root(editor: TextEditor): View {
  return {
    draw() {},
    initialFocus: editor,
    layout: (size) => [{ view: editor, rect: { column: 0, row: size.height - 1, width: size.width, height: 1 } }],
  };
}

test("the palette shows the enabled commands with their descriptions and keys, and a choice runs it with the focus back on the view below", () => {
  const editor = new TextEditor();
  using frame = createFrame({ width: 40, height: 6 }, () => root(editor));
  const tui = frame.surface("notes").tui;
  const focused: boolean[] = [];
  tui.commands.add({
    name: "open",
    description: "Open a note",
    run: () => {
      focused.push(tui.focused === editor);
    },
  });
  tui.commands.add({ name: "shut", run: () => {} });
  tui.commands.add({ name: "off", enabled: () => false, run: () => {} });
  tui.keys.bind("ctrl+x o", "open");
  tui.keys.bind("ctrl+p", "core:palette");
  frame.start();
  frame.key("ctrl+p");
  frame.draw();
  // A core command shows without its prefix.
  equal(rows(frame).slice(0, 3), ["", "/quit  Quit yuke", "/suspend  Suspend yuke to the shell"]);
  // The search reads the label only: no label has the letters of "yuke" in order.
  frame.key("y u k e");
  frame.draw();
  const described = rows(frame).at(1);
  frame.key("ctrl+u n o t e s");
  frame.draw();
  equal(rows(frame).slice(0, 4), ["notes", "/notes:open  Open a note · ctrl+x o", "/notes:shut", ""]);
  frame.key("enter");
  frame.draw();
  equal([described, focused, rows(frame).at(0)], ["", [true], ""]);
  // Ctrl+P in an open palette does not open a second one.
  frame.key("ctrl+p ctrl+p esc");
  frame.draw();
  equal(rows(frame).at(1), "");
});

test("Esc in the palette calls cancel, and a direct close calls no callback", () => {
  using frame = createFrame({ width: 20, height: 4 }, () => root(new TextEditor()));
  const tui = frame.surface("notes").tui;
  const log: string[] = [];
  frame.start();
  tui.palette({ cancel: () => void log.push("cancel") });
  frame.key("esc");
  tui.palette({ cancel: () => void log.push("closed") }).close();
  equal(log, ["cancel"]);
});

test("the surface rejects a command that is no object and a palette cancel that is no function", () => {
  using frame = createFrame({ width: 20, height: 4 });
  const tui = frame.surface("notes").tui;
  // @ts-expect-error: a command is an object.
  const command = throws(() => tui.commands.add(null));
  // @ts-expect-error: a cancel is a function.
  const cancel = throws(() => tui.palette({ cancel: "esc" }));
  equal(
    [String(command), String(cancel)],
    ["TypeError: a command is an object", "TypeError: a palette cancel is a function"],
  );
});
