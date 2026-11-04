// `ChatCommands` of `yuke:chat` above a bare editor: the rows, the scroll, the selection, the labels, and the run.

import { ChatCommands, type ChatCommandsOptions } from "yuke:chat";
import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { type CommandItem, TextEditor } from "yuke:tui";
import { rows } from "./rows.ts";

/** Put a list of `height` rows above a one-row editor in `frame`, with the commands `commands`. */
function mountList(frame: FrameTest, height: number, commands: ChatCommandsOptions["commands"]) {
  const editor = new TextEditor({ multiline: false });
  let list: ChatCommands | undefined;
  frame.surface("demo").tui.wrapRoot((mount) => {
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
  const items: CommandItem[] = names.map((name) => ({ name, slash: name, enabled: true }));
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
  const scrolled = rows(frame.frame).slice(0, 3);
  frame.key("h enter");
  equal([needed, scrolled, ran, list.editor.state.text], [6, [" /alpha3", " /alpha4", " /alpha5"], ["alpha1"], ""]);
});

test("only a command with a slash word lists, and a run that gives false keeps the draft", () => {
  using frame = createFrame({ width: 30, height: 2 });
  const ran: string[] = [];
  const list = mountList(frame, 1, {
    list: () => [
      { name: "core:alpha", slash: "alpha", description: "First", enabled: true },
      { name: "chat:alpine", description: "No word", enabled: true },
    ],
    run: (name) => {
      ran.push(name);
      return false;
    },
  });
  frame.key("/ a l");
  frame.draw();
  const shown = rows(frame.frame)[0];
  const count = list.rows();
  frame.key("enter");
  equal([shown, count, ran, list.editor.state.text], [" /alpha  First", 1, ["core:alpha"], "/al"]);
  // A command without a word has no row at all, also for the text of the missing word.
  list.editor.reset({ text: "/un", selection: { anchor: 3, head: 3 }, spans: [] });
  equal(list.rows(), 0);
});

test("a word and text run the command with args, and only the whole word of a command with a hint matches", () => {
  using frame = createFrame({ width: 30, height: 2 });
  const ran: unknown[][] = [];
  const list = mountList(frame, 1, {
    list: () => [
      { name: "demo:pick", slash: "mode", description: "Pick", argumentHint: "<name>", enabled: true },
      { name: "demo:new", slash: "new", description: "Start", enabled: true },
    ],
    run: (name, args) => {
      ran.push([name, args]);
      return true;
    },
  });
  frame.key("/ m o d e space f a s t");
  frame.draw();
  const shown = rows(frame.frame)[0];
  frame.key("enter");
  equal([shown, ran, list.editor.state.text], [" /mode <name>  Pick", [["demo:pick", "fast"]], ""]);

  // A word alone runs without args, also with a space after it.
  frame.key("/ m o d e space enter");
  equal(ran.at(-1), ["demo:pick", undefined]);
  const count = ran.length;

  // A part of a word, a command without a hint, and an unknown word leave the draft as a message.
  for (const draft of ["/mo x", "/new x", "/usr/bin is slow"]) {
    list.editor.reset({ text: draft, selection: { anchor: draft.length, head: draft.length }, spans: [] });
    equal(list.rows(), 0);
    frame.key("enter");
    equal([ran.length, list.editor.state.text.startsWith(draft)], [count, true]);
  }
});

test("tab writes the selected word without a run, with a space when the command takes text", () => {
  using frame = createFrame({ width: 30, height: 3 });
  const ran: string[] = [];
  const list = mountList(frame, 2, {
    list: () => [
      { name: "demo:model", slash: "model", enabled: true },
      { name: "demo:mode", slash: "mode", argumentHint: "<name>", enabled: true },
    ],
    run: (name) => {
      ran.push(name);
      return true;
    },
  });
  frame.key("/ m o d e l tab");
  equal([list.editor.state.text, list.editor.state.selection.head, ran], ["/model", 6, []]);

  list.editor.reset({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });
  frame.key("/ m o d e tab");
  equal(list.editor.state.text, "/mode ");

  // Tab keeps the text after a word.
  frame.key("x tab");
  equal([list.editor.state.text, ran], ["/mode x", []]);

  // A draft with no match leaves the key to the editor.
  list.editor.reset({ text: "hello", selection: { anchor: 5, head: 5 }, spans: [] });
  frame.key("tab");
  equal(list.editor.state.text, "hello");
});

test("the word of a draft that runs a command has the command style", () => {
  using frame = createFrame({ width: 30, height: 2 });
  const surface = frame.surface("look");
  surface.tui.styles.set({ "chat.command": { fg: 5 } });
  const list = mountList(frame, 1, {
    list: () => [
      { name: "demo:model", slash: "model", enabled: true },
      { name: "demo:mode", slash: "mode", argumentHint: "<name>", enabled: true },
      { name: "demo:off", slash: "off", enabled: false },
    ],
    run: () => true,
  });
  const fgAt = (draft: string, column: number) => {
    list.editor.reset({ text: draft, selection: { anchor: draft.length, head: draft.length }, spans: [] });
    return frame.draw().cells[1]?.[column]?.style.fg;
  };
  equal(fgAt("/model", 0), 5);
  equal(fgAt("/mode fast", 0), 5);
  // The text after the word has no command style.
  equal(fgAt("/mode fast", 6) === 5, false);
  for (const draft of ["/mo", "/model x", "/off", "/nothing"]) equal(fgAt(draft, 0) === 5, false);
});

test("the selected row has a default look that a plugin changes", () => {
  using frame = createFrame({ width: 30, height: 4 });
  mountList(frame, 3, { list: () => [{ name: "alpha", slash: "alpha", enabled: true }], run: () => true });
  const tui = frame.surface("chat").tui;
  frame.key("/ a");
  const row = () => frame.draw().cells[0];
  const before = [row()?.[1]?.style, row()?.[29]?.style];
  tui.styles.set({ "picker.selected": { fg: 1, bg: null } });
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
