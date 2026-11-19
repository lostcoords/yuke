// The bundled plugin `plugins`: the dashboard of the plugins of `config.json` with its sections and keys, the review of
// a check and its apply, the add of a plugin of a repository, the remove, and the sync.

import { apply } from "yuke:internal/bundled/plugins";
import type { PluginManager } from "yuke:internal/sessions";
import type { FoundPlugin, ManagedPlugin, PluginChange, PluginTarget } from "yuke:protocol";
import { assertEquals, createFrame, type FrameTest, test, waitForSettled } from "yuke:test";
import { rows } from "./rows.ts";

const OLD = "3f9c1a2".padEnd(40, "0");
const NEW = "8d02e77".padEnd(40, "0");

const LISTED: readonly ManagedPlugin[] = [
  {
    source: { git: "https://h/r", folder: "plugins/clock" },
    name: "clock",
    state: { kind: "installed", commit: OLD },
    load: { kind: "loaded" },
  },
  { source: "./notes", name: "notes", state: { kind: "local" }, load: { kind: "loaded" } },
  {
    source: { git: "https://h/tools" },
    name: "tools",
    state: { kind: "installed", commit: OLD },
    load: { kind: "pending" },
  },
  { source: { git: "https://h/weather" }, state: { kind: "notInstalled" }, load: { kind: "pending" } },
  { source: { git: "https://h/maps" }, state: { kind: "notInstalled", commit: NEW }, load: { kind: "pending" } },
  {
    source: "./broken",
    name: "broken",
    state: { kind: "local" },
    load: { kind: "failed", error: "plugin broken did not load: Error: no luck" },
  },
];

const CHANGE: PluginChange = {
  name: "clock",
  source: { git: "https://h/r", folder: "plugins/clock" },
  old: OLD,
  new: NEW,
  log: { kind: "commits", commits: ["8d02e77 fix: 12h format", "5b1e0c3 feat: add seconds"] },
};

/** The options of a fake manager. */
interface Fake {
  /** What `check` gives. */
  readonly changes?: readonly PluginChange[];
  /** `check` waits until its signal aborts. */
  readonly hold?: boolean;
  /** `check` and `sync` reject with this text. */
  readonly fail?: string;
  /** What `find` gives. */
  readonly found?: readonly FoundPlugin[];
}

/** A manager that records each call. A sync waits for `syncs.finish` when a test sets `syncs.hold`. */
function manager(fake: Fake = {}) {
  const calls: string[] = [];
  const syncs: { hold: boolean; finish?: () => void } = { hold: false };
  const plugins: PluginManager = {
    list: async () => {
      calls.push("list");
      return { plugins: [...LISTED] };
    },
    sync: async () => {
      calls.push("sync");
      if (syncs.hold) {
        await new Promise<void>((resolve) => {
          syncs.finish = resolve;
        });
      }
      if (fake.fail !== undefined) throw new Error(fake.fail);
      return { plugins: [{ source: CHANGE.source, commit: OLD }], written: true };
    },
    check: (target: PluginTarget, options) => {
      calls.push(`check ${JSON.stringify(target)}`);
      if (fake.fail !== undefined) return Promise.reject(new Error(fake.fail));
      if (fake.hold !== true) return Promise.resolve({ changes: [...(fake.changes ?? [])] });
      return new Promise((_, reject) => {
        options?.signal?.addEventListener("abort", () => {
          calls.push("check stopped");
          reject(options.signal?.reason);
        });
      });
    },
    apply: async (entries) => {
      calls.push(`apply ${entries.map((entry) => `${entry.source.git} ${entry.commit.slice(0, 7)}`).join(", ")}`);
    },
    find: async (params) => {
      calls.push(`find ${params.git}`);
      return { plugins: [...(fake.found ?? [{ name: "news" }])] };
    },
    add: async (params) => {
      calls.push(`add ${JSON.stringify(params)}`);
      return { plugins: [] };
    },
    remove: async (name) => {
      calls.push(`remove ${name}`);
    },
  };
  return { plugins, calls, syncs };
}

/** Load the plugin `plugins` into `frame` with `plugins` as its manager. Give its notices. */
function load(frame: FrameTest, plugins: PluginManager): string[] {
  const tui = frame.surface("plugins").tui;
  const notices: string[] = [];
  const services: Record<string, unknown> = { tui };
  apply(
    {
      get: (name: string) => services[name],
      notify: (level: string, text: string) => notices.push(`${level} ${text}`),
      signal: new AbortController().signal,
    } as never,
    plugins,
  );
  frame.start();
  return notices;
}

/** Open the dashboard, and give the drawn rows after it settles. */
async function open(frame: FrameTest): Promise<string[]> {
  frame.surface("plugins").tui.commands.run("plugins:open");
  await waitForSettled();
  frame.draw();
  return rows(frame.frame);
}

/** Press `keys` in order, and give the drawn rows after they settle. */
async function press(frame: FrameTest, ...keys: [string, ...string[]]): Promise<string[]> {
  for (const key of keys) {
    frame.key(key);
    await waitForSettled();
  }
  frame.draw();
  return rows(frame.frame);
}

/** Type `text` into the open field, press Enter, and give the drawn rows after they settle. */
async function submit(frame: FrameTest, text: string): Promise<string[]> {
  frame.paste(text);
  return press(frame, "enter");
}

const shows = (all: readonly string[], text: string) => all.some((line) => line.includes(text));

/** The row of `all` that holds `text`, with its end trimmed, or "" without one. */
const rowOf = (all: readonly string[], text: string) => all.find((line) => line.includes(text))?.trimEnd() ?? "";

test("the dashboard shows each plugin in its section with its state, and the reason of a plugin that needs attention", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  load(frame, manager().plugins);

  const opened = await open(frame);

  assertEquals(
    [
      rowOf(opened, "Plugins"),
      rowOf(opened, "Needs attention"),
      rowOf(opened, "weather"),
      rowOf(opened, "maps"),
      rowOf(opened, "broken"),
      rowOf(opened, "Git ("),
      rowOf(opened, "clock"),
      rowOf(opened, "tools"),
      rowOf(opened, "Local"),
      rowOf(opened, "notes"),
    ],
    [
      " Plugins · 6",
      " Needs attention (3)",
      "  ! weather  not installed             h/weather",
      "  ! maps     not installed             h/maps",
      "  ✗ broken   failed                    ./broken",
      " Git (2)",
      "  ● clock    loaded           3f9c1a2  h/r · plugins/clock",
      "  ○ tools    reload loads it  3f9c1a2  h/tools",
      " Local (1)",
      "  ● notes    loaded                    ./notes",
    ],
  );
  assertEquals(
    opened.filter((line) => line.startsWith("      ")).map((line) => line.trim()),
    ["s installs it", "s installs it", "plugin broken did not load: Error: no luck"],
  );
  // The first plugin is not installed and has no name, so `u` and `d` do not work on it.
  assertEquals(rowOf(opened, "esc: close"), " s: sync · c: check updates · a: add · r: reload · esc: close");
});

test("u reviews the new commits of the selected plugin, and enter writes them and loads the list again", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager({ changes: [CHANGE] });
  const notices = load(frame, fake.plugins);

  await open(frame);
  const reviewed = await press(frame, "j", "j", "j", "u");
  const after = await press(frame, "enter");

  assertEquals(
    [rowOf(reviewed, "Updates"), rowOf(reviewed, "→"), rowOf(reviewed, "12h"), rowOf(reviewed, "enter:")],
    [" Updates · clock", "clock  3f9c1a2 → 8d02e77", "  8d02e77 fix: 12h format", " enter: update · esc: close"],
  );
  assertEquals(fake.calls, ["list", 'check {"kind":"names","names":["clock"]}', "apply https://h/r 8d02e77", "list"]);
  assertEquals(rowOf(after, "Plugins"), " Plugins · 6 · updated clock · r loads the new commits");
  // The dashboard tells the result in its title, not in a notice.
  assertEquals(notices, []);
});

test("s syncs with a spinner in the title, the keys wait while it runs, and the title counts the installs", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager();
  fake.syncs.hold = true;
  load(frame, fake.plugins);

  await open(frame);
  const running = await press(frame, "s");
  fake.syncs.finish?.();
  await waitForSettled();
  frame.draw();
  const synced = rows(frame.frame);

  assertEquals([rowOf(running, "Plugins"), rowOf(running, "esc: close")], [" Plugins · 6 · ⠋ Syncing…", " esc: close"]);
  assertEquals(fake.calls, ["list", "sync", "list"]);
  assertEquals(rowOf(synced, "Plugins"), " Plugins · 6 · installed 2 plugins · r loads them");
});

test("a failed action gives a notice and leaves the title", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const notices = load(frame, manager({ fail: "the remote is gone" }).plugins);

  await open(frame);
  const after = await press(frame, "s");

  assertEquals(rowOf(after, "Plugins"), " Plugins · 6");
  assertEquals(notices, ["error Syncing failed: the remote is gone"]);
});

test("a adds the one new plugin of a repository, and an empty URL or a repository of known plugins says why", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager();
  load(frame, fake.plugins);

  await open(frame);
  frame.key("a");
  const empty = await press(frame, "enter");
  const added = await submit(frame, " https://h/news ");

  assertEquals(rowOf(empty, "type the URL"), " type the URL of a Git repository");
  assertEquals(fake.calls, ["list", "find https://h/news", 'add {"git":"https://h/news","names":["news"]}', "list"]);
  assertEquals(rowOf(added, "Plugins"), " Plugins · 6 · added news · r loads it");

  using known = createFrame({ width: 100, height: 20 });
  load(known, manager({ found: [{ name: "clock" }] }).plugins);
  await open(known);
  known.key("a");
  const refused = await submit(known, "https://h/r");
  // The prompt stays open with its text after the error.
  assertEquals(
    [rowOf(refused, "config.json has"), rowOf(refused, "https://h/r")],
    [" config.json has each plugin of the repository already", " https://h/r"],
  );
});

test("a repository of more plugins offers its new ones, and the add takes the chosen name", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager({
    found: [
      { name: "clock", folder: "plugins/clock" },
      { name: "sun", folder: "plugins/sun" },
      { name: "moon", folder: "plugins/moon" },
    ],
  });
  load(frame, fake.plugins);

  await open(frame);
  frame.key("a");
  const offered = await submit(frame, "https://h/sky");
  await press(frame, "down", "enter");

  assertEquals(
    [rowOf(offered, "Add a plugin"), rowOf(offered, "sun"), rowOf(offered, "moon"), shows(offered, "clock")],
    [" Add a plugin · h/sky", "sun  plugins/sun", "moon  plugins/moon", false],
  );
  assertEquals(fake.calls.at(-2), 'add {"git":"https://h/sky","names":["moon"]}');
});

test("d asks before it removes the selected plugin, esc keeps it, and enter removes it", async () => {
  using frame = createFrame({ width: 120, height: 20 });
  const fake = manager();
  load(frame, fake.plugins);

  await open(frame);
  const asked = await press(frame, "j", "j", "j", "d");
  await press(frame, "esc");
  const removed = await press(frame, "d", "enter");

  assertEquals(
    [rowOf(asked, "Remove"), rowOf(asked, "yuke removes"), rowOf(asked, "enter:")],
    [
      " Remove clock?",
      "yuke removes clock from config.json and plugins.lock. Its files stay on disk, and it runs until the next reload.",
      " enter: remove · esc: keep",
    ],
  );
  assertEquals(fake.calls, ["list", "remove clock", "list"]);
  assertEquals(rowOf(removed, "Plugins"), " Plugins · 6 · removed clock · r unloads it");
});

test("c checks each plugin, and esc closes the review, stops its check, and keeps the lock", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager({ changes: [CHANGE], hold: true });
  const notices = load(frame, fake.plugins);

  await open(frame);
  const checking = await press(frame, "c");
  const closed = await press(frame, "esc");

  assertEquals(
    [rowOf(checking, "Updates"), shows(checking, "Checking each Git plugin"), shows(closed, "Checking")],
    [" Updates · ⠋ checking…", true, false],
  );
  assertEquals(fake.calls, ["list", 'check {"kind":"all"}', "check stopped"]);
  assertEquals(notices, []);
});

test("a check without a change says so, and enter writes nothing", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager();
  load(frame, fake.plugins);

  await open(frame);
  const reviewed = await press(frame, "c");
  await press(frame, "enter");

  assertEquals(
    [rowOf(reviewed, "Each Git plugin"), rowOf(reviewed, "esc:")],
    ["Each Git plugin is at the newest commit of its ref", " esc: close"],
  );
  assertEquals(fake.calls, ["list", 'check {"kind":"all"}']);
});

test("a check that fails closes the review and gives one error notice", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const notices = load(frame, manager({ fail: "the remote is gone" }).plugins);

  await open(frame);
  const after = await press(frame, "c");

  assertEquals(shows(after, "Checking"), false);
  assertEquals(notices, ["error The check failed: the remote is gone"]);
});

test("the arrow and page keys scroll a long review", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const commits = Array.from({ length: 30 }, (_, index) => `c${String(index).padStart(2, "0")} change ${index}`);
  load(frame, manager({ changes: [{ ...CHANGE, log: { kind: "commits", commits } }] }).plugins);

  await open(frame);
  const top = await press(frame, "c");
  const paged = await press(frame, "pagedown");
  const back = await press(frame, "up");

  assertEquals([shows(top, "c00 change 0"), shows(top, "c20 change 20")], [true, false]);
  assertEquals([shows(paged, "c00 change 0"), shows(paged, "c15 change 15")], [false, true]);
  assertEquals(shows(back, "c09 change 9"), true);
});

test("the selection and its reason stay visible in a dashboard of a few body rows", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  load(frame, manager().plugins);
  // The dialog has 13 rows at the bottom; a body of two rows needs a screen of 4 rows.
  frame.resize({ width: 100, height: 4 });

  const shown = await open(frame);
  const moved = await press(frame, "j", "j");

  assertEquals(shows(shown, "weather"), true);
  assertEquals([shows(moved, "✗ broken"), shows(moved, "no luck")], [true, true]);
});

test("the dashboard draws with the looks of the theme, and a failure has the look of an error", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  load(frame, manager().plugins);
  const shown = await open(frame);
  const title = shown.findIndex((line) => line.includes("Git (2)"));
  const selected = shown.findIndex((line) => line.includes("! weather"));
  const column = shown[title]?.indexOf("Git") ?? 0;
  const mark = shown[selected]?.indexOf("!") ?? 0;
  const failure = shown.findIndex((line) => line.includes("no luck"));
  frame.surface("theme").tui.styles.add({
    "plugins.title": { fg: 1, bold: null },
    "picker.detail": { fg: 2, dim: null },
    "picker.selected": { fg: 3, bg: null },
    "dialog.error": { fg: 4 },
  });
  const cells = frame.draw().cells;

  // The band of the selected row reaches the last column, and the reason below it has the look of a detail.
  assertEquals(
    [
      cells[title]?.[column]?.style,
      cells[selected]?.[mark]?.style,
      cells[selected]?.[99]?.style,
      cells[selected + 1]?.[6]?.style,
      cells[failure]?.[6]?.style,
    ],
    [{ fg: 1 }, { fg: 3 }, { fg: 3 }, { fg: 2 }, { fg: 4 }],
  );
});

test("an empty dashboard tells how to add a plugin", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  load(frame, { ...manager().plugins, list: async () => ({ plugins: [] }) });

  const shown = await open(frame);

  assertEquals(rowOf(shown, "config.json"), " config.json has no plugins · a adds one");
});
