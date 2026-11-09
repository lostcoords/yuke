// The frame test of `yuke:test`: the real core on a grid of cells, with key specs, surfaces, and resizes.

import { createFrame, equal, test } from "yuke:test";
import { TextEditor, type View } from "yuke:tui";

test("a frame holds the cells, the styles, and the cursor that the views drew", () => {
  using frame = createFrame({ width: 6, height: 2 }, () => {
    const input: View = {
      focusable: true,
      draw: (canvas) => {
        canvas.text(0, 0, "中a", { fg: 1, bold: true });
        canvas.text(0, 1, "b", { bg: "#ff0000" });
      },
      cursor: () => ({ column: 3, row: 0, shape: "bar" }),
    };
    return {
      draw() {},
      initialFocus: input,
      layout: () => [{ view: input, rect: { column: 0, row: 0, width: 6, height: 2 } }],
    };
  });
  const red = { fg: 1, bold: true } as const;
  equal(frame.frame.cells[0]?.slice(0, 4), [
    { text: "中", width: 2, style: red },
    { text: "", width: 0, style: red },
    { text: "a", width: 1, style: red },
    { text: " ", width: 1, style: {} },
  ]);
  equal(frame.frame.cells[1]?.[0], { text: "b", width: 1, style: { bg: "#ff0000" } });
  equal(frame.frame.cursor, { column: 3, row: 0, shape: "bar" });
});

test("a view style fills its rect and is the base of each style of the view and its children", () => {
  const editor = new TextEditor({ state: { text: "e", selection: { anchor: 1, head: 1 }, spans: [] } });
  const text: View = {
    draw: (canvas) => {
      canvas.text(0, 0, "a");
      canvas.region(1, 0, 1, 1).text(0, 0, "b", { fg: 1 });
      canvas.text(2, 0, "c", { bg: 3 });
    },
  };
  const inner: View = {
    style: "demo:inner",
    draw: (canvas) => {
      canvas.text(0, 0, "d");
    },
  };
  const outside: View = {
    draw: (canvas) => {
      canvas.text(0, 0, "f");
    },
  };
  using frame = createFrame({ width: 4, height: 4 }, () => ({
    draw() {},
    layout: () => [
      {
        view: {
          style: { bg: 2 },
          draw() {},
          layout: () => [
            { view: text, rect: { column: 0, row: 0, width: 4, height: 1 } },
            { view: inner, rect: { column: 0, row: 1, width: 4, height: 1 } },
            { view: editor, rect: { column: 0, row: 2, width: 2, height: 1 } },
          ],
        },
        rect: { column: 0, row: 0, width: 4, height: 3 },
      },
      { view: outside, rect: { column: 0, row: 3, width: 4, height: 1 } },
    ],
  }));
  frame.surface("demo").tui.styles.set({ "demo:inner": { fg: 4 } });
  const cells = frame.draw().cells;
  equal(cells[0]?.[0]?.style, { bg: 2 });
  equal(cells[0]?.[1]?.style, { fg: 1, bg: 2 });
  equal(cells[0]?.[2]?.style, { bg: 3 });
  // The fill of the view stays where no child draws.
  equal(cells[0]?.[3], { text: " ", width: 1, style: { bg: 2 } });
  equal(cells[1]?.[0]?.style, { fg: 4, bg: 2 });
  equal(cells[1]?.[3]?.style, { fg: 4, bg: 2 });
  equal(cells[2]?.[0], { text: "e", width: 1, style: { bg: 2 } });
  equal(cells[2]?.[3]?.style, { bg: 2 });
  equal(cells[3]?.[0], { text: "f", width: 1, style: {} });
});

test("a list of styles merges per field and a later style wins", () => {
  using frame = createFrame({ width: 4, height: 1 });
  const surface = frame.surface("demo");
  surface.tui.styles.set({ "demo:mark": { fg: 1, bold: true } });
  surface.tui.wrapRoot(() => ({
    draw: (canvas) => {
      canvas.text(0, 0, "a", ["demo:mark", { bold: false, bg: 2 }]);
    },
  }));
  equal(frame.draw().cells[0]?.[0], { text: "a", width: 1, style: { fg: 1, bg: 2 } });
});

test("a dispose closes the root, so the mounts of its widgets end", () => {
  const editor = new TextEditor();
  const frame = createFrame({ width: 4, height: 1 }, () => ({
    draw() {},
    layout: () => [{ view: editor, rect: { column: 0, row: 0, width: 4, height: 1 } }],
  }));
  const signals: AbortSignal[] = [];
  frame.surface("demo").tui.widgets.watch((mount) => {
    signals.push(mount.signal);
    return undefined;
  });
  frame[Symbol.dispose]();
  equal(
    signals.map((signal) => signal.aborted),
    [true],
  );
});

test("the palette color bg of a theme fills each cell of the frame, and the default theme fills nothing", () => {
  using frame = createFrame({ width: 6, height: 2 }, () => ({
    draw: (canvas) => {
      canvas.text(0, 0, "ab");
    },
  }));
  const tui = frame.surface("theme").tui;
  const before = frame
    .draw()
    .cells.flat()
    .map((cell) => cell.style.bg);
  tui.styles.addTheme("dusk", { dark: { palette: { bg: 4 } } });
  tui.styles.setTheme("dusk");
  const themed = frame
    .draw()
    .cells.flat()
    .map((cell) => cell.style.bg);
  equal([before.every((bg) => bg === undefined), themed], [true, Array.from({ length: 12 }, () => 4)]);
});

test("the pane dividers have a default look that a plugin changes", () => {
  using frame = createFrame({ width: 10, height: 4 });
  const tui = frame.surface("theme").tui;
  tui.panes.split(() => ({ draw() {} }));
  tui.panes.split(() => ({ draw() {} }), { direction: "column" });
  const looks = () =>
    ["│", "─"].map(
      (line) =>
        frame
          .draw()
          .cells.flat()
          .find((cell) => cell.text === line)?.style,
    );
  const before = looks();
  tui.styles.set({ "panes.divider": { fg: 1, dim: null } });
  equal(
    [before, looks()],
    [
      [{ dim: true }, { dim: true }],
      [{ fg: 1 }, { fg: 1 }],
    ],
  );
});
