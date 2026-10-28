// The registries of the core of the terminal interface: the keys, the keymap, the commands, the styles, and the
// notices.

import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { Notices } from "yuke:internal/tui/notices";
import { Styles } from "yuke:internal/tui/styles";
import { assert, equal, test, throws } from "yuke:test";
import { type Command, parseKeys, type StylePatch, strokeOf } from "yuke:tui";
import { key, named } from "./terminal.ts";

/** The wait of a sequence in the keymap of the bench. */
const WAIT_MS = 20;

/** The time after which a sequence prefix runs alone, with a margin. */
const AFTER_THE_WAIT_MS = 100;

const ROOT = ["global", "root"];

/**
 * Commands and a keymap that record what they do: `ran` holds the name of each run, or the name and the args; `faults`
 * holds the text of each fault; `frames()` counts the asks for a frame of the commands.
 */
function bench() {
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
    keymap: new Keymap(commands, () => {}, WAIT_MS),
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

test("a sequence prefix runs alone after the wait", async () => {
  const keys = bench();
  keys.add("one");
  keys.add("top");
  keys.keymap.bind("g", "one");
  keys.keymap.bind("g g", "top");
  keys.keymap.key(key("g"), ROOT);
  equal(keys.ran, []);
  equal(keys.keymap.pending(), "g");
  // A busy runtime can fire the timer late, so the test waits for the run, not for a fixed time.
  const deadline = Date.now() + 4000;
  while (keys.ran.length === 0 && Date.now() < deadline) await sleep(20);
  equal(keys.ran, ["one"]);
  equal(keys.keymap.pending(), "");
});

test("escape cancels a sequence and an unmatched stroke goes on as a new key", async () => {
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
  await sleep(AFTER_THE_WAIT_MS);
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
  const first = keymap.bind("ctrl+p", "palette");
  const second = keymap.bind("ctrl+p", "palette");
  keymap.bind("alt+x  p", "palette");
  keymap.bind("ctrl+q", "quit");
  equal(keymap.keysOf("palette"), ["alt+x p", "ctrl+p"]);
  first();
  first();
  equal(keymap.keysOf("palette"), ["alt+x p", "ctrl+p"]);
  second();
  equal(keymap.keysOf("palette"), ["alt+x p"]);
});

test("commands check their names and run with args", () => {
  const keys = bench();
  const dispose = keys.add("notes:open", { title: "Open a note" });
  keys.add("off", { enabled: () => false });
  const bad = [
    () => keys.add("notes:open"),
    () => keys.add("a b"),
    () => keys.add(""),
    // @ts-expect-error: a command has a run function.
    () => keys.commands.add({ name: "x" }),
    // @ts-expect-error: a title is a string.
    () => keys.add("t", { title: 7 }),
    // @ts-expect-error: an enabled check is a function.
    () => keys.add("e", { enabled: true }),
  ];
  for (const call of bad) assert(throws(call) instanceof TypeError);
  // A later change of the object changes neither the name nor the title.
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
    { name: "notes:open", title: "Open a note", enabled: true },
    { name: "off", title: "off", enabled: false },
    { name: "first", title: "first", enabled: true },
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
  // biome-ignore lint/suspicious/noThenProperty: a thenable that is no `Promise` fails too.
  const thenable = { then: (_resolve: () => void, reject: (error: Error) => void) => reject(new Error("no then")) };
  // @ts-expect-error: a run gives no thenable that is no `Promise`.
  keys.commands.add({ name: "thenable", run: () => thenable });
  keys.add("next");
  keys.keymap.bind("d", "dialog");
  keys.keymap.bind("n", "next");
  keys.keymap.key(key("d"), ROOT);
  keys.keymap.key(key("n"), ROOT);
  // Frames: five adds before the keys; then one per run that ends.
  equal(keys.ran, ["next"]);
  equal(keys.frames(), 6);
  assert(finish !== undefined);
  finish();
  await null;
  equal(keys.frames(), 7);
  keys.commands.run("broken");
  keys.commands.run("sync");
  keys.commands.run("thenable");
  for (let turn = 0; turn < 5; turn += 1) await null;
  equal(keys.frames(), 10);
  equal(
    keys.faults.map((fault) => fault.split("\n")[0]),
    [
      "the command sync failed: Error: bad state",
      "the command broken failed: Error: no disk",
      "the command thenable failed: Error: no then",
    ],
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
  // A palette checks each command on each frame, so a broken check reports once until a new registration.
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
  styles.set("title", { fg: 3, bold: true });
  const newer = styles.set("title", { fg: "#102030", bold: null, italic: true });
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
  styles.set("base", { fg: 1, bg: 2, underline: true });
  styles.set("title", { link: "base", fg: 5 });
  equal(styles.resolve("title"), { fg: 5, bg: 2, underline: true });
  equal(styles.resolve({ link: "title", bg: "reset" }), { fg: 5, bg: "reset", underline: true });
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
    own.set("a", { link: "b", bold: true });
    own.set("b", { link: "a", dim: true });
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
  styles.set("accent", { fg: "accent", bg: "reset" });
  equal(styles.resolve("accent").fg, "#A8CFA0");
  background = "light";
  equal(styles.resolve("accent").fg, "#2D6A4F");
  truecolor = false;
  equal(styles.resolve("accent").fg, 29);
  equal(styles.resolve({ bg: "danger" }).bg, 124);
});

test("a bad style field throws", () => {
  const styles = new Styles(
    () => true,
    () => "dark",
    () => {},
  );
  const bad: StylePatch[] = [
    // @ts-expect-error: `red` is no color.
    { fg: "red" },
    // @ts-expect-error: `toString` is no palette color.
    { fg: "toString" },
    { fg: 256 },
    // @ts-expect-error: a flag is a boolean.
    { bold: 1 },
    // @ts-expect-error: `color` is no style field.
    { color: 1 },
    { link: "" },
  ];
  for (const patch of bad) assert(throws(() => styles.set("a", patch)) instanceof TypeError, JSON.stringify(patch));
  assert(throws(() => styles.set("", {})) instanceof TypeError);
  // @ts-expect-error: a style to resolve has no `null`.
  assert(throws(() => styles.resolve({ fg: null })) instanceof TypeError);
  styles.set("a", { fg: null, bg: "surface", underlineColor: "#ABCDEF" });
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

test("each registration and its disposer ask for a frame", () => {
  let asked = 0;
  const ask = () => {
    asked += 1;
  };
  const keymap = new Keymap(bench().commands, ask);
  const styles = new Styles(
    () => true,
    () => "dark",
    ask,
  );
  const unbind = keymap.bind("x", "test:x");
  const unset = styles.set("title", { bold: true });
  equal(asked, 2);
  unbind();
  unset();
  // A second call of a disposer changes nothing, so it asks for no frame.
  unbind();
  unset();
  equal(asked, 4);
});
