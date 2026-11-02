// `ChatCommands` of `yuke:chat` above a bare editor: the rows, the scroll, the selection, the labels, and the run.

import { ChatCommands, type ChatCommandsOptions, chatStyles } from "yuke:chat";
import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { type CommandItem, TextEditor } from "yuke:tui";
import { rows } from "./chat.ts";

/** Put a list of `height` rows above a one-row editor in `frame`, with the commands `commands`. */
function mountList(frame: FrameTest, height: number, commands: ChatCommandsOptions["commands"]) {
  const editor = new TextEditor({ multiline: false });
  let list: ChatCommands | undefined;
  frame.surface("demo").tui.setRoot((mount) => {
    list = new ChatCommands(editor, { commands, signal: mount.signal, enabled: () => true });
    const view = list.view;
    return {
      draw() {},
      initialFocus: editor,
      layout: (size) => [
        { view, rect: { column: 0, row: 0, width: size.width, height } },
        { view: editor, rect: { column: 0, row: height, width: size.width, height: 1 } },
      ],
    };
  });
  return { editor, rows: () => list?.rows };
}

test("the list needs at most six rows, a shorter place scrolls to the selection, and an edit selects the best match", () => {
  using frame = createFrame({ width: 30, height: 4 });
  const ran: string[] = [];
  const names = Array.from({ length: 8 }, (_, at) => `alpha${at + 1}`);
  const items: CommandItem[] = names.map((name) => ({ name, enabled: true }));
  const list = mountList(frame, 3, {
    list: () => items,
    run: (name) => {
      ran.push(name);
      return true;
    },
  });
  frame.key("/ a l p");
  const needed = list.rows();
  frame.key("down down down down");
  frame.draw();
  const scrolled = rows(frame).slice(0, 3);
  frame.key("h enter");
  equal([needed, scrolled, ran, list.editor.state.text], [6, [" /alpha3", " /alpha4", " /alpha5"], ["alpha1"], ""]);
});

test("a core command shows without its prefix, and a run that the registry refuses keeps the draft", () => {
  using frame = createFrame({ width: 30, height: 2 });
  const ran: string[] = [];
  const list = mountList(frame, 1, {
    list: () => [{ name: "core:alpha", description: "First", enabled: true }],
    run: (name) => {
      ran.push(name);
      return false;
    },
  });
  frame.key("/ a l");
  frame.draw();
  const shown = rows(frame)[0];
  frame.key("enter");
  equal([shown, ran, list.editor.state.text], [" /alpha  First", ["core:alpha"], "/al"]);
});

test("the selected row has a default look that a plugin changes", () => {
  using frame = createFrame({ width: 30, height: 4 });
  mountList(frame, 3, { list: () => [{ name: "alpha", enabled: true }], run: () => true });
  // The bundled chat sets these groups for a chat.
  const tui = frame.surface("chat").tui;
  tui.styles.set(chatStyles);
  frame.key("/ a");
  const row = () => frame.draw().cells[0];
  const before = [row()?.[1]?.style, row()?.[29]?.style];
  tui.styles.set({ "chat.commands.selected": { fg: 1, bg: null } });
  equal(
    [before, row()?.[1]?.style],
    [
      [
        { fg: "#e6edf3", bg: "#355c4a" },
        { fg: "#e6edf3", bg: "#355c4a" },
      ],
      { fg: 1 },
    ],
  );
});
