// The bundled plugin `plugins`: the dashboard of the plugins of `config.json` with its sections and keys, the review of
// a check, its apply, its stop, and the sync.

import { apply } from "yuke:internal/bundled/plugins";
import type { PluginManager } from "yuke:plugins";
import type { ManagedPlugin, PluginChange, PluginTarget } from "yuke:protocol";
import { createFrame, equal, type FrameTest, test } from "yuke:test";
import { rows, settle } from "./chat.ts";

const OLD = "3f9c1a2".padEnd(40, "0");
const NEW = "8d02e77".padEnd(40, "0");
const SOURCE = "https://h/r (folder plugins/clock)";

const LISTED: readonly ManagedPlugin[] = [
  { item: SOURCE, name: "clock", loaded: true, state: "installed", commit: OLD },
  { item: "./notes", name: "notes", loaded: true, state: "local" },
  { item: "https://h/tools", name: "tools", loaded: false, state: "installed", commit: OLD },
  { item: "https://h/weather", loaded: false, state: "not_locked" },
  { item: "https://h/maps", loaded: false, state: "not_installed", commit: NEW },
];

const CHANGE: PluginChange = {
  name: "clock",
  source: { git: "https://h/r", folder: "plugins/clock" },
  old: OLD,
  new: NEW,
  log: { commits: ["8d02e77 fix: 12h format", "5b1e0c3 feat: add seconds"] },
};

/**
 * A manager that records each call. `check` gives `changes`. With `hold` it waits until its signal aborts, and with
 * `fail` it rejects with that text.
 */
function manager(changes: readonly PluginChange[], hold = false, fail?: string) {
  const calls: string[] = [];
  // A sync waits for `finish` when a test sets `syncs.hold`.
  const syncs: { hold: boolean; finish?: () => void } = { hold: false };
  const plugins: PluginManager = {
    list: async () => {
      calls.push("list");
      return { plugins: [...LISTED] };
    },
    sync: async (options) => {
      calls.push(`sync ${String(options?.locked)} ${options?.signal === undefined ? "without" : "with"} a signal`);
      if (syncs.hold) {
        await new Promise<void>((resolve) => {
          syncs.finish = resolve;
        });
      }
      return { plugins: [{ source: CHANGE.source, commit: OLD }], written: true };
    },
    check: (target: PluginTarget, options) => {
      calls.push(`check ${JSON.stringify(target)}`);
      if (fail !== undefined) return Promise.reject(new Error(fail));
      if (!hold) return Promise.resolve({ changes: [...changes] });
      return new Promise((_, reject) => {
        options?.signal?.addEventListener("abort", () => {
          calls.push("check stopped");
          reject(options.signal?.reason);
        });
      });
    },
    apply: async (chosen) => {
      calls.push(`apply ${chosen.map((change) => `${change.name} ${change.new.slice(0, 7)}`).join(", ")}`);
      return { written: true };
    },
    add: async (plugin) => {
      calls.push(`add ${JSON.stringify(plugin.source)}`);
      return { name: "news", source: plugin.source, commit: NEW };
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
  const services: Record<string, unknown> = { tui, plugins };
  apply({
    get: (name: string) => services[name],
    notify: (level: string, text: string) => notices.push(`${level} ${text}`),
    signal: new AbortController().signal,
  } as never);
  frame.start();
  return notices;
}

/** Run `command`, and give the drawn rows after it settles. */
async function run(frame: FrameTest, command: string): Promise<string[]> {
  frame.surface("plugins").tui.commands.run(command);
  await settle();
  frame.draw();
  return rows(frame);
}

/** Press `keys` in order, and give the drawn rows after they settle. */
async function press(frame: FrameTest, ...keys: string[]): Promise<string[]> {
  for (const key of keys) {
    frame.key(key);
    await settle();
  }
  // A call without keys still waits, so work that a test released ends first.
  await settle();
  frame.draw();
  return rows(frame);
}

const shows = (all: readonly string[], text: string) => all.some((line) => line.includes(text));

test("the dashboard shows the plugins in sections with their state, and enter shows the details", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  load(frame, fake.plugins);

  const opened = await run(frame, "plugins:open");
  const detailed = await press(frame, "j", "j", "enter");
  const hidden = await press(frame, "enter");

  equal(
    [
      shows(opened, "Plugins · 5"),
      shows(opened, "Needs sync (2)"),
      shows(opened, "! ?            https://h/weather  not locked"),
      shows(opened, "! ?            https://h/maps  8d02e77 not installed"),
      shows(opened, "Installed (2)"),
      shows(opened, `● clock        ${SOURCE}  3f9c1a2`),
      shows(opened, "○ tools        https://h/tools  3f9c1a2 not loaded"),
      shows(opened, "Local (1)"),
      shows(opened, "● notes        ./notes"),
    ],
    [true, true, true, true, true, true, true, true, true],
  );
  // The first plugin needs a sync and has no name, so `u` and `d` do not work on it.
  equal(shows(opened, "S: sync · U: update all · a: add · /: search · R: reload · esc: close"), true);
  equal(
    [
      shows(detailed, `${SOURCE} · commit ${OLD} · loaded`),
      shows(detailed, "u: update · a: add · d: remove"),
      shows(hidden, `commit ${OLD}`),
    ],
    [true, true, false],
  );
});

test("u reviews the new commits of the selected plugin, and enter writes them and loads the list again", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([CHANGE]);
  const notices = load(frame, fake.plugins);

  await run(frame, "plugins:open");
  const reviewed = await press(frame, "j", "j", "u");
  const after = await press(frame, "enter");

  equal([shows(reviewed, "clock  3f9c1a2 → 8d02e77"), shows(reviewed, "  8d02e77 fix: 12h format")], [true, true]);
  equal(shows(reviewed, "enter: write plugins.lock · esc: close"), true);
  equal(fake.calls, ["list", 'check {"names":["clock"]}', "apply clock 8d02e77", "list"]);
  equal(shows(after, "Plugins · 5 · plugins.lock written: R reloads"), true);
  // The dashboard tells the result in its title, not in a notice.
  equal(notices, []);
});

test("S syncs and shows the result in the title, and the actions wait while it runs", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  fake.syncs.hold = true;
  load(frame, fake.plugins);

  await run(frame, "plugins:open");
  const running = await press(frame, "S");
  fake.syncs.finish?.();
  const synced = await press(frame);

  equal(
    [shows(running, "Plugins · 5 · syncing"), shows(running, "S: sync"), shows(running, "/: search")],
    [true, false, false],
  );
  equal(fake.calls, ["list", "sync undefined with a signal", "list"]);
  equal(shows(synced, "Plugins · 5 · plugins.lock written: R reloads"), true);
});

test("a adds the plugin of a line in the form of yuke plugin add, and a line without a URL says why", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  load(frame, fake.plugins);

  await run(frame, "plugins:open");
  frame.key("a");
  frame.paste("https://h/news --folder p --ref v1");
  const added = await press(frame, "enter");
  frame.key("a");
  frame.paste("--ref v1");
  const refused = await press(frame, "enter");

  equal(fake.calls, ["list", 'add {"git":"https://h/news","folder":"p","ref":"v1"}', "list"]);
  equal(shows(added, "news added at 8d02e77: R reloads"), true);
  equal(shows(refused, "Error: give the URL of the repository first"), true);
  // The prompt stays open with its draft after the error.
  equal(shows(refused, "--ref v1"), true);
});

test("d asks before it removes the selected plugin, and esc keeps it", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  load(frame, fake.plugins);

  await run(frame, "plugins:open");
  const asked = await press(frame, "j", "j", "d");
  await press(frame, "esc");
  const removed = await press(frame, "d", "enter");

  equal(shows(asked, "Remove clock from config.json and plugins.lock?"), true);
  equal(fake.calls, ["list", "remove clock", "list"]);
  equal(shows(removed, "clock removed: R reloads"), true);
});

test("/ finds a plugin by its name and selects it", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  load(frame, fake.plugins);

  await run(frame, "plugins:open");
  frame.key("/");
  frame.paste("tools");
  await press(frame, "enter", "u");

  equal(fake.calls, ["list", 'check {"names":["tools"]}']);
});

test("esc closes the review, stops its check, and keeps the lock", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([CHANGE], true);
  const notices = load(frame, fake.plugins);

  const checking = await run(frame, "plugins:update");
  const closed = await press(frame, "esc");

  equal(
    [shows(checking, "the check of the Git plugins runs"), shows(closed, "the check of the Git plugins runs")],
    [true, false],
  );
  equal(fake.calls, ['check "all"', "check stopped"]);
  equal(notices, []);
});

test("a check without a change says so, and enter writes nothing", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  load(frame, fake.plugins);

  const reviewed = await run(frame, "plugins:update");
  await press(frame, "enter");

  equal(
    [shows(reviewed, "each Git plugin is at the newest commit of its ref"), shows(reviewed, "esc: close")],
    [true, true],
  );
  equal(fake.calls, ['check "all"']);
});

test("a check that fails closes the review and gives one error notice", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([], false, "the remote is gone");
  const notices = load(frame, fake.plugins);

  const after = await run(frame, "plugins:update");

  equal(shows(after, "the check of the Git plugins runs"), false);
  equal(notices, ["error the update failed: Error: the remote is gone"]);
});

test("the arrow and page keys scroll a long review", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const commits = Array.from({ length: 30 }, (_, index) => `c${String(index).padStart(2, "0")} change ${index}`);
  const fake = manager([{ ...CHANGE, log: { commits } }]);
  load(frame, fake.plugins);

  const top = await run(frame, "plugins:update");
  const paged = await press(frame, "page_down");
  const back = await press(frame, "up");

  equal([shows(top, "c00 change 0"), shows(top, "c20 change 20")], [true, false]);
  equal([shows(paged, "c00 change 0"), shows(paged, "c15 change 15")], [false, true]);
  equal(shows(back, "c09 change 9"), true);
});

test("the sync command tells its start and its result", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  const notices = load(frame, fake.plugins);

  await run(frame, "plugins:sync");

  equal(fake.calls, ["sync undefined with a signal"]);
  equal(notices, ["info the sync of the Git plugins runs", "info plugins.lock written: run /reload"]);
});

test("the command update writes the chosen commits with a notice", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([CHANGE]);
  const notices = load(frame, fake.plugins);

  await run(frame, "plugins:update");
  await press(frame, "enter");

  equal(fake.calls, ['check "all"', "apply clock 8d02e77"]);
  equal(notices, ["info plugins.lock written: run /reload to load the new commits"]);
});

test("the selection stays visible in a dashboard of one body row", async () => {
  using frame = createFrame({ width: 100, height: 20 });
  const fake = manager([]);
  load(frame, fake.plugins);
  // The dialog has 13 rows at the bottom; a body of one row needs a screen of 3 rows.
  frame.resize({ width: 100, height: 3 });

  const shown = await run(frame, "plugins:open");
  const moved = await press(frame, "j", "j", "enter");

  equal(shows(shown, "https://h/weather"), true);
  equal(shows(moved, "clock"), true);
});
