// The themes of a plugin: the bundled plugin `themes`, the picker and the saved choice.

import { readTextFile, writeTextFile } from "yuke:fs";
import { apply } from "yuke:internal/bundled/themes";
import { createFrame, equal, type FrameTest, folder, test, waitForSettled } from "yuke:test";
import type { Tui } from "yuke:tui";
import { rows } from "./rows.ts";

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
  await waitForSettled();
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
  await waitForSettled();
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
