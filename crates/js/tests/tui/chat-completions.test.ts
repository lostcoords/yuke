// `ChatCompletions` of `yuke:chat` above a bare editor: the rows, the scroll, the selection, the labels, the run, the
// order of the providers, and a late list. The slash commands are the provider of the bundled chat.

import { ChatCompletions, type CompletionProvider, type SlashCommands, slashCompletions } from "yuke:chat";
import { assert, assertEquals, createFrame, type FrameTest, test, waitForSettled } from "yuke:test";
import { type CommandItem, TextEditor } from "yuke:tui";
import { rows } from "./rows.ts";

/** Put a list of `height` rows above a one-row editor in `frame`, with the providers `providers`. */
function mountProviders(frame: FrameTest, height: number, providers: readonly CompletionProvider[]) {
  const editor = new TextEditor({ multiline: false });
  const errors: unknown[] = [];
  let changes = 0;
  let list: ChatCompletions | undefined;
  frame.surface("demo").tui.wrapRoot((mount) => {
    list = new ChatCompletions(editor, {
      providers: () => providers,
      cwd: () => "/w",
      signal: mount.signal,
      enabled: () => true,
      onChange: () => {
        changes += 1;
      },
      onError: (error) => errors.push(error),
    });
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
  return { editor, errors, rows: () => list?.rows, changes: () => changes };
}

/** Put a list of the slash commands `commands` above a one-row editor in `frame`. */
function mountList(frame: FrameTest, height: number, commands: SlashCommands) {
  return mountProviders(frame, height, [slashCompletions(commands)]);
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
  assertEquals(
    [needed, scrolled, ran, list.editor.state.text],
    [6, [" /alpha3", " /alpha4", " /alpha5"], ["alpha1"], ""],
  );
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
  assertEquals([shown, count, ran, list.editor.state.text], [" /alpha  First", 1, ["core:alpha"], "/al"]);
  // A command without a word has no row at all, also for the text of the missing word.
  list.editor.reset({ text: "/un", selection: { anchor: 3, head: 3 }, spans: [] });
  assertEquals(list.rows(), 0);
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
  assertEquals([shown, ran, list.editor.state.text], [" /mode <name>  Pick", [["demo:pick", "fast"]], ""]);

  // A word alone runs without args, also with a space after it.
  frame.key("/ m o d e space enter");
  assertEquals(ran.at(-1), ["demo:pick", undefined]);
  const count = ran.length;

  // A part of a word, a command without a hint, and an unknown word leave the draft as a message.
  for (const draft of ["/mo x", "/new x", "/usr/bin is slow"]) {
    list.editor.reset({ text: draft, selection: { anchor: draft.length, head: draft.length }, spans: [] });
    assertEquals(list.rows(), 0);
    frame.key("enter");
    assertEquals([ran.length, list.editor.state.text.startsWith(draft)], [count, true]);
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
  assertEquals([list.editor.state.text, list.editor.state.selection.head, ran], ["/model", 6, []]);

  list.editor.reset({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });
  frame.key("/ m o d e tab");
  assertEquals(list.editor.state.text, "/mode ");

  // Tab keeps the text after a word.
  frame.key("x tab");
  assertEquals([list.editor.state.text, ran], ["/mode x", []]);

  // A draft with no match leaves the key to the editor.
  list.editor.reset({ text: "hello", selection: { anchor: 5, head: 5 }, spans: [] });
  frame.key("tab");
  assertEquals(list.editor.state.text, "hello");
});

test("the selected row has a default look that a plugin changes", () => {
  using frame = createFrame({ width: 30, height: 4 });
  mountList(frame, 3, { list: () => [{ name: "alpha", slash: "alpha", enabled: true }], run: () => true });
  const tui = frame.surface("chat").tui;
  frame.key("/ a");
  const row = () => frame.draw().cells[0];
  // The band reaches the last cell of the row. The cell 4 is past the match `/a`, so it has the selected look alone.
  const before = [row()?.[4]?.style.bg, row()?.[29]?.style.bg];
  assert(before[0] !== undefined);
  tui.styles.add({ "picker.selected": { fg: 1, bg: null } });
  assertEquals([before[1], row()?.[4]?.style], [before[0], { fg: 1 }]);
});

/** A provider that completes `@` words with `names`, and records each context that it reads. */
function mentions(names: readonly string[], seen: string[] = []): CompletionProvider {
  return {
    complete: (context) => {
      seen.push(context.text);
      const word = /(?:^|\s)@(\S*)$/.exec(context.text.slice(0, context.caret));
      if (word === null) return undefined;
      const query = word[1] as string;
      const items = names.filter((name) => name.startsWith(query));
      return {
        from: context.caret - query.length - 1,
        items: items.map((name) => ({ label: `@${name}`, insert: `@${name}` })),
      };
    },
  };
}

test("the newest provider with an item wins, and a provider without one leaves the draft to the next", () => {
  using frame = createFrame({ width: 30, height: 3 });
  const older = mentions(["src/main.rs"]);
  const newer = mentions(["docs/"]);
  const list = mountProviders(frame, 2, [newer, older]);
  frame.key("s e e space @ d");
  frame.draw();
  const first = rows(frame.frame)[0];
  frame.key("backspace s");
  frame.draw();
  assertEquals([first, rows(frame.frame)[0], list.rows()], [" @docs/", " @src/main.rs", 1]);
});

test("tab writes the item in place of the word before the caret, and the next ask lists again from there", () => {
  using frame = createFrame({ width: 30, height: 3 });
  const list = mountProviders(frame, 2, [mentions(["src/", "src/main.rs"])]);
  frame.key("r e a d space @ s tab");
  const written = list.editor.state.text;
  frame.key("m tab");
  assertEquals([written, list.editor.state.text, list.editor.caret], ["read @src/", "read @src/main.rs", 17]);
});

test("enter writes an item without a run, and esc hides the list until the next edit", () => {
  using frame = createFrame({ width: 30, height: 3 });
  const list = mountProviders(frame, 2, [mentions(["notes.md"])]);
  frame.key("@ n esc");
  const hidden = list.rows();
  frame.key("enter");
  const sent = list.editor.state.text;
  frame.key("o enter");
  assertEquals([hidden, sent, list.editor.state.text], [0, "@n", "@notes.md"]);
});

test("a late list shows when its draft is still current, and a list for an older draft never shows", async () => {
  using frame = createFrame({ width: 30, height: 3 });
  const answers: ((names: readonly string[]) => void)[] = [];
  const late: CompletionProvider = {
    complete: (context) =>
      new Promise((resolve) => {
        answers.push((names) =>
          resolve({ from: 0, items: names.map((name) => ({ label: `${context.text}${name}`, insert: name })) }),
        );
      }),
  };
  const list = mountProviders(frame, 2, [late]);
  frame.key("a");
  frame.key("b");
  // The ask of `a` comes back after the draft became `ab`.
  answers[1]?.(["1"]);
  answers[2]?.(["2"]);
  await waitForSettled();
  frame.draw();
  assertEquals([rows(frame.frame)[0], list.changes()], [" ab2", 1]);
});

test("a throw or a rejection of a provider is an error, and the ask goes on to the next provider", async () => {
  using frame = createFrame({ width: 30, height: 3 });
  const thrower: CompletionProvider = {
    complete: () => {
      throw new Error("broken");
    },
  };
  const rejecter: CompletionProvider = { complete: async () => Promise.reject(new Error("gone")) };
  const list = mountProviders(frame, 2, [thrower, rejecter, mentions(["x"])]);
  frame.key("@");
  await waitForSettled();
  frame.draw();
  assertEquals(
    [list.errors.map((error) => (error as Error).message), rows(frame.frame)[0]],
    [["broken", "broken", "gone"], " @x"],
  );
});
