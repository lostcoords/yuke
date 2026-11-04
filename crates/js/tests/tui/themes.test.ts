// The themes of a plugin: the bundled plugin `themes`, the picker and the saved choice, and the event `theme.changed`.

import { readTextFile, writeTextFile } from "yuke:fs";
import { apply } from "yuke:internal/bundled/themes";
import { on } from "yuke:internal/facts";
import { Core } from "yuke:internal/tui/core";
import { createSurface } from "yuke:internal/tui/surface";
import { createFrame, equal, type FrameTest, folder, settled, test } from "yuke:test";
import { Markdown, type Tui } from "yuke:tui";
import { rows } from "./rows.ts";
import { fakeTerminal } from "./terminal.ts";

/** Load the plugin in `frame` on the folder `dataDir`, and give the theme author surface and the notices. */
async function load(frame: FrameTest, dataDir: string): Promise<{ tui: Tui; notices: string[] }> {
  const surface = frame.surface("themes");
  const notices: string[] = [];
  await apply({
    get: () => surface.tui,
    dataDir,
    notify: (level: string, text: string) => notices.push(`${level} ${text}`),
  } as never);
  return { tui: frame.surface("author").tui, notices };
}

/** The color of a text in `accent` on `frame`. */
function accent(frame: FrameTest, tui: Tui): unknown {
  tui.wrapRoot(() => ({ draw: (canvas) => canvas.text(0, 0, "x", { fg: "accent" }) }));
  return frame.draw().cells[0]?.[0]?.style.fg;
}

const NORD = { dark: { palette: { accent: 1 } } } as const;
const DAWN = { dark: { palette: { accent: 2 } } } as const;

test("the picker shows a theme at once, esc gives the old one back, and enter saves the new one", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const dataDir = folder();
  const { tui } = await load(frame, dataDir);
  tui.styles.addTheme("nord", NORD);
  tui.styles.addTheme("dawn", DAWN);
  const base = accent(frame, tui);
  const open = (): void => {
    frame.surface("themes").tui.commands.run("themes:open");
    frame.draw();
  };

  open();
  const listed = rows(frame.frame).join("\n");
  frame.key("down");
  const preview = tui.styles.theme;
  frame.key("esc");
  const canceled = tui.styles.theme;

  // A query without a result keeps the theme from before it.
  open();
  frame.key("down z z z");
  const noResult = tui.styles.theme;
  frame.key("esc");

  open();
  frame.key("n o r d enter");
  await settled();
  equal(await readTextFile("theme.json", { baseDir: dataDir }), '{"name":"nord"}');
  equal(
    [
      ["default", "nord", "dawn"].every((name) => listed.includes(name)),
      preview,
      canceled,
      noResult,
      tui.styles.theme,
      accent(frame, tui) !== base,
    ],
    [true, "nord", "default", "nord", "nord", true],
  );
});

test("a saved theme applies at the load, also when its plugin comes later, and default clears it", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const dataDir = folder();
  await writeTextFile("theme.json", JSON.stringify({ name: "nord" }), { baseDir: dataDir });
  const { tui, notices } = await load(frame, dataDir);
  const active = tui.styles.theme;
  tui.styles.addTheme("nord", NORD);
  const color = accent(frame, tui);

  frame.surface("themes").tui.commands.run("themes:open");
  frame.draw();
  frame.key("d e f enter");
  await settled();
  equal(await readTextFile("theme.json", { baseDir: dataDir }), '{"name":"default"}');
  equal([active, color, tui.styles.theme, notices], ["nord", 1, "default", []]);
});

test("a saved file without a name gives the default theme and no notice", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const dataDir = folder();
  await writeTextFile("theme.json", "{}", { baseDir: dataDir });
  const { tui, notices } = await load(frame, dataDir);
  equal([tui.styles.theme, notices], ["default", []]);
});

test("the picker opens on the active theme, so its first selection changes nothing", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const { tui } = await load(frame, folder());
  tui.styles.addTheme("nord", NORD);
  tui.styles.setTheme("nord");
  frame.surface("themes").tui.commands.run("themes:open");
  frame.draw();
  equal(tui.styles.theme, "nord");
});

test("a bad saved file is a notice, and yuke starts on the default theme", async () => {
  using frame = createFrame({ width: 40, height: 10 });
  const dataDir = folder();
  await writeTextFile("theme.json", "{", { baseDir: dataDir });
  const { tui, notices } = await load(frame, dataDir);
  equal([tui.styles.theme, notices.length, notices[0]?.startsWith("error the saved theme")], ["default", 1, true]);
});

test("theme.changed tells each new theme and each new background", () => {
  const core = new Core(fakeTerminal().driver);
  const stop = new AbortController();
  const seen: unknown[] = [];
  on("author", stop.signal, "theme.changed", (data) => seen.push([data.name, data.background]));
  on("author", stop.signal, "notice", () => seen.push("a notice"));
  core.styles.setTheme("nord");
  core.styles.setTheme("nord");
  core.event({ type: "background", background: "light" });
  stop.abort();
  core.styles.setTheme("default");
  equal(seen, [
    ["nord", "dark"],
    ["nord", "light"],
  ]);
});

test("the abort of a plugin that owns the active theme and listens gives that plugin no call", () => {
  const core = new Core(fakeTerminal().driver);
  const stop = new AbortController();
  const tui = createSurface(core, "pack", stop.signal);
  const other = new AbortController();
  const seen: string[] = [];
  let own = 0;
  on("pack", stop.signal, "theme.changed", () => {
    own += 1;
    return tui.styles.theme;
  });
  on("other", other.signal, "theme.changed", (data) => seen.push(data.name));
  tui.styles.addTheme("nord", {});
  tui.styles.setTheme("nord");
  const before = own;
  stop.abort();
  other.abort();
  // The other plugin still hears of the removal of the theme.
  equal([own - before, seen], [0, ["nord", "nord"]]);
});

test("the palette color fg of a theme reaches the plain text of a Markdown text", () => {
  using frame = createFrame({ width: 20, height: 2 });
  const tui = frame.surface("author").tui;
  const rows = new Markdown("plain **bold**").rows(20);
  tui.wrapRoot(() => ({
    draw: (canvas) => {
      let column = 0;
      for (const segment of rows[0]?.segments ?? []) column = canvas.text(column, 0, segment.text, segment.style);
    },
  }));
  tui.styles.addTheme("nord", { dark: { palette: { fg: 3 } } });
  tui.styles.setTheme("nord");
  const cells = frame.draw().cells[0];
  equal([cells?.[0]?.style, cells?.[6]?.style], [{ fg: 3 }, { fg: 3, bold: true }]);
});

test("a plugin supports a theme for now, and the theme wins once it names the group", () => {
  using frame = createFrame({ width: 10, height: 2 });
  const tui = frame.surface("b").tui;
  const stop = new AbortController();
  tui.styles.set({ "b.title": { fg: 9, bold: true } });
  let undo = (): void => {};
  const look = (): void => {
    undo();
    undo = tui.styles.theme === "nord" ? tui.styles.set({ "b.title": { fg: 3 } }) : () => {};
  };
  on("b", stop.signal, "theme.changed", look);
  const color = (): unknown => {
    tui.wrapRoot(() => ({ draw: (canvas) => canvas.text(0, 0, "x", "b.title") }));
    return frame.draw().cells[0]?.[0]?.style;
  };
  const before = color();
  tui.styles.addTheme("nord", {});
  tui.styles.setTheme("nord");
  const supported = color();
  tui.styles.addTheme("nord", { dark: { groups: { "b.title": { fg: 5 } } } });
  const native = color();
  tui.styles.setTheme("default");
  const left = color();
  stop.abort();
  equal(
    [before, supported, native, left],
    [
      { fg: 9, bold: true },
      { fg: 3, bold: true },
      { fg: 5, bold: true },
      { fg: 9, bold: true },
    ],
  );
});
