// The styles of the core: the event `theme.changed`, and a theme against the palette, the plugin styles, and Markdown.

import { on } from "yuke:internal/facts";
import { Core } from "yuke:internal/tui/core";
import { createSurface } from "yuke:internal/tui/surface";
import { assertEquals, createFrame, test } from "yuke:test";
import { Markdown } from "yuke:tui";
import { fakeTerminal } from "./terminal.ts";

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
  assertEquals(seen, [
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
  assertEquals([own - before, seen], [0, ["nord", "nord"]]);
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
  assertEquals([cells?.[0]?.style, cells?.[6]?.style], [{ fg: 3 }, { fg: 3, bold: true }]);
});

test("a plugin supports a theme for now, and the theme wins once it names the group", () => {
  using frame = createFrame({ width: 10, height: 2 });
  const tui = frame.surface("b").tui;
  const stop = new AbortController();
  tui.styles.add({ "b.title": { fg: 9, bold: true } });
  let undo = (): void => {};
  const look = (): void => {
    undo();
    undo = tui.styles.theme === "nord" ? tui.styles.add({ "b.title": { fg: 3 } }) : () => {};
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
  assertEquals(
    [before, supported, native, left],
    [
      { fg: 9, bold: true },
      { fg: 3, bold: true },
      { fg: 5, bold: true },
      { fg: 9, bold: true },
    ],
  );
});
