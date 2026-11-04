// The registries of the core of the terminal interface: the keys, the keymap, the commands, the styles, and the
// notices.

import { ManualClock } from "yuke:internal/tui/clock";
import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { Notices } from "yuke:internal/tui/notices";
import { Styles } from "yuke:internal/tui/styles";
import { assert, equal, settled, test, throws } from "yuke:test";
import { type Command, parseKeys, strokeOf } from "yuke:tui";
import { key, named } from "./terminal.ts";

/** The wait of a sequence for its next stroke. */
const WAIT_MS = 1000;

const ROOT = ["global", "root"];

/**
 * Commands and a keymap that record what they do. `ran` holds the name of each run, or the name and the args.
 * `faults` holds the text of each fault. `frames()` counts the asks for a frame of the commands. `clock` times the
 * keymap.
 */
function bench() {
  const clock = new ManualClock();
  const ran: unknown[] = [];
  const faults: string[] = [];
  let frames = 0;
  const commands = new Commands(
    (_name, text) => {
      faults.push(text);
    },
    () => {
      frames += 1;
    },
  );
  return {
    ran,
    faults,
    commands,
    clock,
    keymap: new Keymap(commands, () => {}, clock.after),
    frames: () => frames,
    /** Add the command `name` that records its run. `extra` adds or replaces fields. */
    add: (name: string, extra: Partial<Command> = {}) =>
      commands.add({
        name,
        run: (args) => {
          ran.push(args === undefined ? name : [name, args]);
        },
        ...extra,
      }),
  };
}

test("a spec and an event fold to the same stroke", () => {
  const specs = [
    "G",
    "shift+g",
    "ctrl+shift+A",
    "?",
    "ctrl+space",
    "shift+space",
    "ctrl++",
    "+",
    "shift+tab",
    " ctrl+x   ctrl+s ",
    "alt+super+f35",
    "esc",
  ];
  equal(
    specs.map((spec) => parseKeys(spec)),
    [
      ["G"],
      ["G"],
      ["ctrl+a"],
      ["?"],
      ["ctrl+space"],
      ["space"],
      ["ctrl++"],
      ["+"],
      ["shift+tab"],
      ["ctrl+x", "ctrl+s"],
      ["alt+super+f35"],
      ["esc"],
    ],
  );
  const events = [
    key("g", { shift: true }, { shifted: "G" }),
    key("g", { shift: true }),
    key("A", { ctrl: true, shift: true }),
    key("/", { shift: true }, { shifted: "?" }),
    key(" ", { ctrl: true }),
    key(" ", { shift: true }),
    key("+", { ctrl: true }),
    named("tab", { shift: true }),
    named("esc"),
    named("unknown"),
    key(""),
    key("с", { ctrl: true }, { baseLayout: "c" }),
    key("x", { hyper: true }),
    key("x", { meta: true }),
  ];
  // The Cyrillic key keeps its own stroke: a binding matches the typed key only. Hyper and meta take no binding.
  equal(
    events.map((event) => strokeOf(event)),
    ["G", "G", "ctrl+a", "?", "ctrl+space", "space", "ctrl++", "shift+tab", "esc", "", "", "ctrl+с", "", ""],
  );
});

test("a spec that names no key throws", () => {
  for (const spec of ["", "   ", "ctrl+", "hyper+a", "enterr", "+a", "a+", "shift+1", "shift++"]) {
    assert(throws(() => parseKeys(spec)) instanceof TypeError, `'${spec}' throws a TypeError`);
  }
  // @ts-expect-error: a spec is a string.
  assert(throws(() => parseKeys(5)) instanceof TypeError);
  equal(parseKeys("ctrl+a"), ["ctrl+a"]);
});

test("the deepest active atom wins then the newest binding", () => {
  const keys = bench();
  for (const name of ["older", "newer", "list", "global"]) keys.add(name);
  // The deepest binding is the oldest, so only its depth makes it win.
  keys.keymap.bind("ctrl+k", "list", { in: "list" });
  keys.keymap.bind("ctrl+k", "older");
  keys.keymap.bind("ctrl+k", "newer");
  keys.keymap.bind("ctrl+g", "global", { in: "global" });
  const taken = [
    keys.keymap.key(key("k", { ctrl: true }), ROOT),
    keys.keymap.key(key("k", { ctrl: true }), [...ROOT, "list"]),
    keys.keymap.key(key("k", { ctrl: true }), ["global", "overlay"]),
    keys.keymap.key(key("g", { ctrl: true }), ["global", "overlay"]),
  ];
  equal(keys.ran, ["newer", "list", "global"]);
  equal(taken, [true, true, false, true]);
});

test("a disabled command passes its key on and at last to the view", () => {
  const keys = bench();
  keys.add("open");
  keys.add("closed", { enabled: () => false });
  keys.keymap.bind("x", "open");
  keys.keymap.bind("x", "closed");
  keys.keymap.bind("y", "closed");
  keys.keymap.bind("z", "missing");
  const taken = ["x", "y", "z"].map((character) => keys.keymap.key(key(character), ROOT));
  equal(keys.ran, ["open"]);
  equal(taken, [true, false, false]);
});

test("a sequence waits for its next stroke", () => {
  const keys = bench();
  keys.add("save");
  keys.keymap.bind("ctrl+x ctrl+s", "save");
  equal(keys.keymap.key(key("x", { ctrl: true }), ROOT), true);
  equal(keys.keymap.pending(), "ctrl+x");
  equal(keys.ran, []);
  equal(keys.keymap.key(key("s", { ctrl: true }), ROOT), true);
  equal(keys.ran, ["save"]);
  equal(keys.keymap.pending(), "");
});

test("a sequence prefix runs alone after the wait", () => {
  const keys = bench();
  keys.add("one");
  keys.add("top");
  keys.keymap.bind("g", "one");
  keys.keymap.bind("g g", "top");
  keys.keymap.key(key("g"), ROOT);
  keys.clock.advance(WAIT_MS - 1);
  equal([keys.ran, keys.keymap.pending()], [[], "g"]);
  keys.clock.advance(1);
  equal([keys.ran, keys.keymap.pending()], [["one"], ""]);
});

test("escape cancels a sequence and an unmatched stroke goes on as a new key", () => {
  const keys = bench();
  keys.add("save");
  keys.add("alpha");
  keys.add("prefix");
  keys.keymap.bind("ctrl+x ctrl+s", "save");
  keys.keymap.bind("ctrl+x", "prefix");
  keys.keymap.bind("a", "alpha");
  keys.keymap.key(key("x", { ctrl: true }), ROOT);
  const escaped = keys.keymap.key(named("esc"), ROOT);
  keys.keymap.key(key("x", { ctrl: true }), ROOT);
  const unmatched = keys.keymap.key(key("a"), ROOT);
  keys.keymap.key(key("x", { ctrl: true }), ROOT);
  keys.keymap.cancel();
  const after = keys.keymap.key(key("b"), ROOT);
  // The prefix binding never runs: escape, an unmatched stroke, and a cancel each drop it.
  equal([escaped, unmatched, after], [true, true, false]);
  equal(keys.ran, ["alpha"]);
  equal(keys.keymap.pending(), "");
  keys.clock.advance(WAIT_MS);
  equal(keys.ran, ["alpha"]);
});

test("a binding outside the active atoms neither runs nor starts a sequence", () => {
  const keys = bench();
  keys.add("save");
  keys.add("quit");
  keys.keymap.bind("ctrl+x ctrl+s", "save", { in: "editor" });
  keys.keymap.bind("ctrl+x", "quit");
  equal(keys.keymap.key(key("x", { ctrl: true }), ROOT), true);
  equal(keys.ran, ["quit"]);
  equal(keys.keymap.pending(), "");
});

test("a deeper single key runs before a shallower sequence and a disabled sequence takes no key", () => {
  const keys = bench();
  keys.add("top");
  keys.add("down");
  keys.add("closed", { enabled: () => false });
  keys.keymap.bind("g g", "top");
  keys.keymap.bind("g", "down", { in: "list" });
  keys.keymap.bind("z z", "closed");
  keys.keymap.bind("q q", "missing");
  equal(keys.keymap.key(key("g"), [...ROOT, "list"]), true);
  equal(keys.keymap.pending(), "");
  equal(keys.ran, ["down"]);
  equal(keys.keymap.key(key("g"), ROOT), true);
  equal(keys.keymap.pending(), "g");
  keys.keymap.cancel();
  equal([keys.keymap.key(key("z"), ROOT), keys.keymap.key(key("q"), ROOT)], [false, false]);
  equal(keys.keymap.pending(), "");
});

test("a disposer during a wait cancels the wait", () => {
  const keys = bench();
  keys.add("save");
  const dispose = keys.keymap.bind("ctrl+x ctrl+s", "save");
  keys.keymap.key(key("x", { ctrl: true }), ROOT);
  equal(keys.keymap.pending(), "ctrl+x");
  dispose();
  equal(keys.keymap.pending(), "");
});

test("keys of a command and each disposer remove only their own binding", () => {
  const keymap = bench().keymap;
  const first = keymap.bind("ctrl+o", "open");
  const second = keymap.bind("ctrl+o", "open");
  keymap.bind("alt+x  o", "open");
  keymap.bind("ctrl+q", "quit");
  equal(keymap.keysOf("open"), ["alt+x o", "ctrl+o"]);
  first();
  first();
  equal(keymap.keysOf("open"), ["alt+x o", "ctrl+o"]);
  second();
  equal(keymap.keysOf("open"), ["alt+x o"]);
});

test("commands check their names and run with args", () => {
  const keys = bench();
  const dispose = keys.add("notes:open", { description: "Open a note" });
  keys.add("off", { enabled: () => false });
  const bad = [
    () => keys.add("notes:open"),
    () => keys.add("a b"),
    () => keys.add(""),
    // @ts-expect-error: a command has a run function.
    () => keys.commands.add({ name: "x" }),
    // @ts-expect-error: a description is a string.
    () => keys.add("t", { description: 7 }),
    // @ts-expect-error: an enabled check is a function.
    () => keys.add("e", { enabled: true }),
  ];
  for (const call of bad) assert(throws(call) instanceof TypeError);
  // A later change of the object changes neither the name nor the description.
  const renamed = {
    name: "first",
    run: () => {
      keys.ran.push("first");
    },
  };
  keys.commands.add(renamed);
  renamed.name = "second";
  equal(
    [
      keys.commands.run("notes:open", { id: 3 }),
      keys.commands.run("off"),
      keys.commands.run("missing"),
      keys.commands.run("first"),
      keys.commands.run("second"),
    ],
    [true, false, false, true, false],
  );
  equal(keys.ran, [["notes:open", { id: 3 }], "first"]);
  equal(keys.commands.list(), [
    { name: "notes:open", description: "Open a note", enabled: true },
    { name: "off", enabled: false },
    { name: "first", enabled: true },
  ]);
  dispose();
  dispose();
  equal(keys.commands.run("notes:open"), false);
  // Frames: three adds, two runs, and the disposer each ask for one.
  equal(keys.frames(), 6);
});

test("an async command lets keys go on and a failure names it", async () => {
  const keys = bench();
  let finish: (() => void) | undefined;
  keys.commands.add({
    name: "dialog",
    run: () =>
      new Promise<void>((resolve) => {
        finish = resolve;
      }),
  });
  keys.commands.add({
    name: "broken",
    run: async () => {
      throw new Error("no disk");
    },
  });
  keys.commands.add({
    name: "sync",
    run: () => {
      throw new Error("bad state");
    },
  });
  keys.add("next");
  keys.keymap.bind("d", "dialog");
  keys.keymap.bind("n", "next");
  keys.keymap.key(key("d"), ROOT);
  keys.keymap.key(key("n"), ROOT);
  // Four commands add frames before the keys. Each run that ends adds one frame.
  equal(keys.ran, ["next"]);
  equal(keys.frames(), 5);
  assert(finish !== undefined);
  finish();
  await settled();
  equal(keys.frames(), 6);
  keys.commands.run("broken");
  keys.commands.run("sync");
  await settled();
  equal(keys.frames(), 8);
  equal(
    keys.faults.map((fault) => fault.split("\n")[0]),
    ["the command sync failed: Error: bad state", "the command broken failed: Error: no disk"],
  );
});

test("a throwing enabled check counts as disabled and faults once per registration", () => {
  const keys = bench();
  const flaky = {
    enabled: () => {
      throw new Error("no state");
    },
  };
  const dispose = keys.add("flaky", flaky);
  equal(keys.commands.run("flaky"), false);
  keys.commands.list();
  keys.commands.list();
  keys.commands.run("flaky");
  // A list of commands checks each command on each frame, so a broken check reports once until a new registration.
  equal(keys.faults.length, 1);
  dispose();
  keys.add("flaky", flaky);
  keys.commands.run("flaky");
  equal(keys.ran, []);
  equal(keys.faults.length, 2);
  equal(keys.faults[0]?.split("\n")[0], "the enabled check of the command flaky failed: Error: no state");
});

test("the newest style layer wins per field and null deletes", () => {
  const styles = new Styles(
    () => true,
    () => "dark",
    () => {},
  );
  styles.set({ title: { fg: 3, bold: true } });
  const newer = styles.set({ title: { fg: "#102030", bold: null, italic: true } });
  equal(styles.resolve("title"), { fg: "#102030", italic: true });
  newer();
  newer();
  equal(styles.resolve("title"), { fg: 3, bold: true });
  equal(styles.resolve("none"), {});
});

test("a link fills the missing fields and a cycle stops", () => {
  const styles = new Styles(
    () => true,
    () => "dark",
    () => {},
  );
  styles.set({ base: { fg: 1, bg: 2, underline: true } });
  styles.set({ title: { inherits: "base", fg: 5 } });
  equal(styles.resolve("title"), { fg: 5, bg: 2, underline: true });
  equal(styles.resolve({ inherits: "title", bg: "reset" }), { fg: 5, bg: "reset", underline: true });
  // Each order of the first resolves gives the same result in a cycle. The fields of a link come first.
  for (const order of [
    ["a", "b"],
    ["b", "a"],
  ]) {
    const own = new Styles(
      () => true,
      () => "dark",
      () => {},
    );
    own.set({ a: { inherits: "b", bold: true } });
    own.set({ b: { inherits: "a", dim: true } });
    for (const name of order) own.resolve(name);
    equal(Object.entries(own.resolve("a")), [
      ["dim", true],
      ["bold", true],
    ]);
    equal(Object.entries(own.resolve("b")), [
      ["bold", true],
      ["dim", true],
    ]);
  }
});

test("a palette color follows the depth and the background", () => {
  let truecolor = true;
  let background: "dark" | "light" = "dark";
  const styles = new Styles(
    () => truecolor,
    () => background,
    () => {},
  );
  styles.set({ accent: { fg: "accent", bg: "reset" } });
  equal(styles.resolve("accent").fg, "#A8CFA0");
  background = "light";
  equal(styles.resolve("accent").fg, "#2D6A4F");
  truecolor = false;
  equal(styles.resolve("accent").fg, 29);
  equal(styles.resolve({ bg: "danger" }).bg, 124);
});

test("notices keep the last hundred and count a repeat", () => {
  const notices = new Notices();
  const seen: [string, number][] = [];
  const dispose = notices.on((notice) => seen.push([notice.text, notice.count]));
  notices.add("error", "notes", "broken");
  notices.add("error", "notes", "broken");
  notices.add("warn", "notes", "broken");
  dispose();
  dispose();
  for (let index = 0; index < 120; index += 1) notices.add("info", "host:yuke", `n${index}`);
  const list = notices.list();
  equal(seen, [
    ["broken", 1],
    ["broken", 2],
    ["broken", 1],
  ]);
  equal(list.length, 100);
  equal([list[0]?.text, list.at(-1)?.text], ["n20", "n119"]);
  assert(Object.isFrozen(list[0]), "a notice is frozen");
});

test("a notice of another session is no repeat", () => {
  const notices = new Notices();
  notices.add("warn", "lint", "3 errors", "a");
  notices.add("warn", "lint", "3 errors", "b");
  notices.add("warn", "lint", "3 errors", "b");
  notices.add("warn", "lint", "3 errors");
  equal(
    notices.list().map((notice) => [notice.sessionId, notice.count]),
    [
      ["a", 1],
      ["b", 2],
      [undefined, 1],
    ],
  );
});

test("each registration and its disposer ask for a frame", () => {
  let asked = 0;
  const ask = () => {
    asked += 1;
  };
  const keymap = new Keymap(bench().commands, ask, new ManualClock().after);
  const styles = new Styles(
    () => true,
    () => "dark",
    ask,
  );
  const unbind = keymap.bind("x", "test:x");
  const unset = styles.set({ title: { bold: true } });
  equal(asked, 2);
  unbind();
  unset();
  // A second call of a disposer changes nothing, so it asks for no frame.
  unbind();
  unset();
  equal(asked, 4);
});

test("one set changes many groups with one frame and one disposer", () => {
  let asked = 0;
  const styles = new Styles(
    () => true,
    () => "dark",
    () => {
      asked += 1;
    },
  );
  const undo = styles.set({ a: { fg: 1 }, b: { fg: 2 } });
  const both = [styles.resolve("a"), styles.resolve("b")];
  const framesOfSet = asked;
  undo();
  equal([both, framesOfSet, styles.resolve("a"), styles.resolve("b"), asked], [[{ fg: 1 }, { fg: 2 }], 1, {}, {}, 2]);
});

/** Styles on a dark 24-bit terminal, with the background and the depth that a test can change. */
function themed() {
  const state = { truecolor: true, background: "dark" as "dark" | "light", changes: 0 };
  const styles = new Styles(
    () => state.truecolor,
    () => state.background,
    () => {},
    () => {
      state.changes += 1;
    },
  );
  return { state, styles };
}

test("a theme changes nothing until it is active, and its groups win over each set per field", () => {
  const { styles } = themed();
  styles.set({ title: { fg: 1, bold: true } });
  styles.addTheme("nord", { dark: { groups: { title: { fg: 2, underline: true } } } });
  const before = styles.resolve("title");
  styles.setTheme("nord");
  const active = styles.resolve("title");
  styles.set({ title: { fg: 3, italic: true } });
  const later = styles.resolve("title");
  styles.setTheme("default");
  equal(
    [before, active, later, styles.resolve("title")],
    [
      { fg: 1, bold: true },
      { fg: 2, bold: true, underline: true },
      { fg: 2, bold: true, italic: true, underline: true },
      { fg: 3, bold: true, italic: true },
    ],
  );
});

test("a group that a theme does not name follows the palette of the theme, also through a link", () => {
  const { styles } = themed();
  styles.set({
    "b.title": { fg: "accent", bold: true },
    "b.link": { inherits: "b.title" },
    "b.fixed": { fg: "#ff0000" },
  });
  styles.addTheme("nord", { dark: { palette: { accent: "#88c0d0" } } });
  styles.setTheme("nord");
  equal(
    [styles.resolve("b.title"), styles.resolve("b.link"), styles.resolve("b.fixed")],
    [{ fg: "#88c0d0", bold: true }, { fg: "#88c0d0", bold: true }, { fg: "#ff0000" }],
  );
});

test("a theme gives the look of the background, and one look serves both", () => {
  const { state, styles } = themed();
  styles.set({ title: { fg: "accent" } });
  styles.addTheme("two", { dark: { palette: { accent: 1 } }, light: { palette: { accent: 2 } } });
  styles.addTheme("one", { light: { palette: { accent: 3 } } });
  styles.setTheme("two");
  const dark = styles.resolve("title").fg;
  state.background = "light";
  const light = styles.resolve("title").fg;
  styles.setTheme("one");
  const onlyLight = styles.resolve("title").fg;
  state.background = "dark";
  equal([dark, light, onlyLight, styles.resolve("title").fg], [1, 2, 3, 3]);
});

test("a theme inherits by name in any order, wins per field, and a cycle stops", () => {
  const { styles } = themed();
  styles.setTheme("mine");
  styles.addTheme("mine", {
    inherits: "nord",
    dark: { palette: { danger: 7 }, groups: { title: { fg: 2, bold: null } } },
  });
  styles.addTheme("nord", {
    dark: { palette: { accent: 5, danger: 6 }, groups: { title: { fg: 1, bold: true, underline: true } } },
  });
  styles.set({ a: { fg: "accent" }, d: { fg: "danger" } });
  equal([styles.resolve("title"), styles.resolve("a").fg, styles.resolve("d").fg], [{ fg: 2, underline: true }, 5, 7]);
  styles.addTheme("nord", { inherits: "mine", dark: { palette: { accent: 8 } } });
  equal(styles.resolve("a").fg, 8);
});

test("the newest theme of a name wins, and its remover gives the older one back", () => {
  const { state, styles } = themed();
  styles.set({ a: { fg: "accent" } });
  styles.setTheme("nord");
  const first = state.changes;
  styles.addTheme("nord", { dark: { palette: { accent: 1 } } });
  const undo = styles.addTheme("nord", { dark: { palette: { accent: 2 } } });
  const newest = styles.resolve("a").fg;
  undo();
  undo();
  equal([newest, styles.resolve("a").fg, styles.themes(), state.changes - first], [2, 1, ["default", "nord"], 3]);
});

test("the change of the look of the active theme is told once, and another theme is not told", () => {
  const { state, styles } = themed();
  styles.addTheme("other", {});
  equal(state.changes, 0);
  styles.setTheme("nord");
  styles.setTheme("nord");
  equal(state.changes, 1);
  const undo = styles.addTheme("nord", {});
  equal(state.changes, 2);
  const other = styles.addTheme("base", {});
  equal(state.changes, 2);
  other();
  equal(state.changes, 2);
  undo();
  equal(state.changes, 3);
  styles.setTheme("default");
  equal(state.changes, 4);
});

test("style and theme registration copy their fields before the first resolve", () => {
  const { styles } = themed();
  const patch = { fg: 1 };
  const groups = { title: patch };
  styles.set(groups);
  patch.fg = 2;
  groups.title = { fg: 3 };
  const palette = { accent: 4 };
  const themePatch = { bg: 5 };
  const theme = { dark: { palette, groups: { title: themePatch } } };
  styles.addTheme("mine", theme);
  palette.accent = 6;
  themePatch.bg = 7;
  theme.dark = { palette: { accent: 8 }, groups: { title: { bg: 9 } } };
  styles.setTheme("mine");

  equal(styles.resolve("title"), { fg: 1, bg: 5 });
  equal(styles.resolve({ fg: "accent" }), { fg: 4 });
  styles.set({ unrelated: { bold: true } });
  equal(styles.resolve("title"), { fg: 1, bg: 5 });
});

test("the default theme name is reserved", () => {
  const { styles } = themed();
  assert(throws(() => styles.addTheme("default", {})) instanceof TypeError);
  equal(styles.themes(), ["default"]);
});

test("the palette color fg reaches each cell without a color, and it wins over no color that a style sets", () => {
  const { state, styles } = themed();
  styles.set({
    plain: { bold: true },
    colored: { fg: 1 },
    band: { bg: 2 },
    reset: { fg: "reset" },
  });
  const onDefault = [styles.cell(undefined), styles.cell("plain"), styles.cell(["colored", "band"])];
  styles.addTheme("nord", { dark: { palette: { fg: "#eceff4" } } });
  styles.setTheme("nord");
  const fg = "#eceff4";
  const themedCells = [
    styles.cell(undefined),
    styles.cell("unknown"),
    styles.cell("plain"),
    styles.cell({ italic: true }),
    styles.cell(["plain", "band"]),
    styles.cell(["colored", "band"]),
    styles.cell("reset"),
    styles.cell([]),
  ];
  state.truecolor = false;
  equal(
    [onDefault, themedCells, styles.cell(undefined)],
    [
      [{}, { bold: true }, { fg: 1, bg: 2 }],
      [
        { fg },
        { fg },
        { fg, bold: true },
        { fg, italic: true },
        { fg, bold: true, bg: 2 },
        { fg: 1, bg: 2 },
        { fg: "reset" },
        { fg },
      ],
      { fg: 255 },
    ],
  );
});

test("the palette color bg reaches each cell without a background, and fg stays apart from it", () => {
  const { state, styles } = themed();
  styles.set({
    plain: { bold: true },
    band: { bg: 2 },
    colored: { fg: 1 },
    terminal: { bg: "reset" },
    reversed: { reverse: true },
  });
  styles.addTheme("dusk", { dark: { palette: { bg: "#2e3440" } } });
  styles.addTheme("both", { dark: { palette: { fg: 5, bg: 6 } } });
  styles.setTheme("dusk");
  const bg = "#2e3440";
  const dusk = [
    styles.cell(undefined),
    styles.cell("plain"),
    styles.cell("band"),
    styles.cell(["colored", "plain"]),
    styles.cell("terminal"),
    styles.cell("reversed"),
  ];
  styles.setTheme("both");
  const both = [styles.cell(undefined), styles.cell("colored"), styles.cell("band"), styles.cell(["colored", "band"])];
  styles.setTheme("dusk");
  state.truecolor = false;
  equal(
    [dusk, both, styles.cell(undefined)],
    [
      [{ bg }, { bold: true, bg }, { bg: 2 }, { fg: 1, bold: true, bg }, { bg: "reset" }, { reverse: true, bg }],
      [
        { fg: 5, bg: 6 },
        { fg: 1, bg: 6 },
        { fg: 5, bg: 2 },
        { fg: 1, bg: 2 },
      ],
      { bg: 237 },
    ],
  );
});

test("a terminal without 24-bit color gets the nearest index for each hex color", () => {
  const { state, styles } = themed();
  state.truecolor = false;
  styles.set({
    red: { fg: "#ff0000" },
    white: { fg: "#ffffff" },
    gray: { bg: "#808080" },
    mid: { fg: "#87afd7" },
    index: { fg: 9 },
    reset: { fg: "reset" },
    themed: { fg: "accent" },
  });
  styles.addTheme("hex", { dark: { palette: { accent: "#000000" } } });
  styles.setTheme("hex");
  equal(
    [
      styles.resolve("red").fg,
      styles.resolve("white").fg,
      styles.resolve("gray").bg,
      styles.resolve("mid").fg,
      styles.resolve("index").fg,
      styles.resolve("reset").fg,
      styles.resolve("themed").fg,
    ],
    [196, 231, 244, 110, 9, "reset", 16],
  );
});

test("the default theme sits below each set and each other theme, and a name that it holds keeps its other fields", () => {
  const { styles } = themed();
  equal(
    [styles.theme, styles.resolve("chat.error").fg, styles.resolve("chat.error").bold],
    ["default", "#FF7B72", true],
  );
  const undo = styles.set({ "chat.error": { fg: 1 } });
  equal(styles.resolve("chat.error"), { fg: 1, bold: true });
  styles.addTheme("nord", { dark: { groups: { "chat.error": { fg: 2 } } } });
  styles.setTheme("nord");
  equal(styles.resolve("chat.error"), { fg: 2, bold: true });
  styles.setTheme("default");
  undo();
  equal(styles.resolve("chat.error"), { fg: "#FF7B72", bold: true });
});

test("a theme with a 256-color palette uses it only without 24-bit color, and inherits the rest", () => {
  const { state, styles } = themed();
  styles.set({ a: { fg: "accent" }, d: { fg: "danger" }, w: { fg: "warn" } });
  styles.addTheme("base", { dark: { palette: { warn: 7 } } });
  styles.addTheme("nord", {
    inherits: "base",
    dark: { palette: { accent: "#ff0000", danger: "#00ff00" }, palette256: { accent: 99 } },
  });
  styles.setTheme("nord");
  const colors = () => [styles.resolve("a").fg, styles.resolve("d").fg, styles.resolve("w").fg];
  const truecolor = colors();
  state.truecolor = false;
  equal(
    [truecolor, colors()],
    [
      ["#ff0000", "#00ff00", 7],
      [99, 46, 7],
    ],
  );
});
