// The bundled plugin `plugins`: the list of the plugins of `config.json`, the review of a check, its apply, its stop,
// and the sync.

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
  const plugins: PluginManager = {
    list: async () => {
      calls.push("list");
      return { plugins: [...LISTED] };
    },
    sync: async (options) => {
      calls.push(`sync ${String(options?.locked)} ${options?.signal === undefined ? "without" : "with"} a signal`);
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
  };
  return { plugins, calls };
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

const shows = (all: readonly string[], text: string) => all.some((line) => line.includes(text));

test("the list shows each plugin with its state, and enter on a Git plugin reviews its new commits", async () => {
  using frame = createFrame({ width: 90, height: 16 });
  const fake = manager([CHANGE]);
  const notices = load(frame, fake.plugins);

  const listed = await run(frame, "plugins:open");
  frame.key("enter");
  await settle();
  frame.draw();
  const reviewed = rows(frame);
  frame.key("enter");
  await settle();
  frame.draw();

  equal(
    [
      shows(listed, `● clock  ${SOURCE} · 3f9c1a2 · loaded`),
      shows(listed, "● notes  ./notes · local · loaded"),
      shows(listed, "○ tools  https://h/tools · 3f9c1a2 · not loaded"),
      shows(listed, "! ?  https://h/weather · not locked: /plugins:sync"),
      shows(listed, "! ?  https://h/maps · 8d02e77 not installed: /plugins:sync"),
    ],
    [true, true, true, true, true],
  );
  equal(
    [
      shows(reviewed, "clock  3f9c1a2 → 8d02e77"),
      shows(reviewed, "  8d02e77 fix: 12h format"),
      shows(reviewed, "enter: write plugins.lock · esc: keep it"),
      shows(reviewed, "enter: check a Git plugin"),
      shows(rows(frame), "clock  3f9c1a2 → 8d02e77"),
      shows(rows(frame), "enter: check a Git plugin"),
    ],
    [true, true, true, false, false, false],
  );
  equal(fake.calls, ["list", 'check {"names":["clock"]}', "apply clock 8d02e77"]);
  equal(notices, ["info plugins.lock written: run /reload to load the new commits"]);
});

test("esc closes the review, stops its check, and keeps the lock", async () => {
  using frame = createFrame({ width: 90, height: 16 });
  const fake = manager([CHANGE], true);
  const notices = load(frame, fake.plugins);

  const checking = await run(frame, "plugins:update");
  frame.key("esc");
  await settle();
  frame.draw();

  equal(shows(checking, "the check of the Git plugins runs"), true);
  equal(shows(rows(frame), "the check of the Git plugins runs"), false);
  equal(fake.calls, ['check "all"', "check stopped"]);
  equal(notices, []);
});

test("a check without a change says so, and enter writes nothing", async () => {
  using frame = createFrame({ width: 90, height: 16 });
  const fake = manager([]);
  load(frame, fake.plugins);

  const reviewed = await run(frame, "plugins:update");
  frame.key("enter");
  await settle();

  equal(
    [shows(reviewed, "each Git plugin is at the newest commit of its ref"), shows(reviewed, "esc: close")],
    [true, true],
  );
  equal(fake.calls, ['check "all"']);
});

test("the sync tells its start and its result", async () => {
  using frame = createFrame({ width: 90, height: 16 });
  const fake = manager([]);
  const notices = load(frame, fake.plugins);

  await run(frame, "plugins:sync");

  equal(fake.calls, ["sync undefined with a signal"]);
  equal(notices, ["info the sync of the Git plugins runs", "info plugins.lock written: run /reload"]);
});

test("a check that fails closes the review and gives one error notice", async () => {
  using frame = createFrame({ width: 90, height: 16 });
  const fake = manager([], false, "the remote is gone");
  const notices = load(frame, fake.plugins);

  const after = await run(frame, "plugins:update");

  equal(shows(after, "the check of the Git plugins runs"), false);
  equal(notices, ["error the check failed: Error: the remote is gone"]);
});

test("the arrow and page keys scroll a long review", async () => {
  using frame = createFrame({ width: 90, height: 16 });
  const commits = Array.from({ length: 30 }, (_, index) => `c${String(index).padStart(2, "0")} change ${index}`);
  const fake = manager([{ ...CHANGE, log: { commits } }]);
  load(frame, fake.plugins);

  const top = await run(frame, "plugins:update");
  frame.key("page_down");
  frame.draw();
  const paged = rows(frame);
  frame.key("up");
  frame.draw();

  equal([shows(top, "c00 change 0"), shows(top, "c20 change 20")], [true, false]);
  equal([shows(paged, "c00 change 0"), shows(paged, "c15 change 15")], [false, true]);
  equal(shows(rows(frame), "c09 change 9"), true);
});
