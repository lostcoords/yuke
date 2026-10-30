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

test("advance runs the due timers of the frame and draws a frame", () => {
  let text = "wait";
  using frame = createFrame({ width: 6, height: 1 }, () => ({
    draw: (canvas) => {
      canvas.text(0, 0, text);
    },
  }));
  frame.surface("clock").tui.after(1000, () => {
    text = "done";
  });
  frame.advance(999);
  const before = frame.frame.cells[0]?.[0]?.text;
  frame.advance(1);
  equal([before, frame.frame.cells[0]?.[0]?.text], ["w", "d"]);
});

test("keys of a spec reach the bindings of a surface and the stop of a surface removes them", () => {
  using frame = createFrame({ width: 8, height: 1 });
  const surface = frame.surface("demo");
  surface.tui.commands.add({ name: "copy", run: () => surface.tui.copy("copied") });
  surface.tui.keys.bind("ctrl+k y", "copy");
  frame.key("ctrl+k y");
  equal(frame.copies, ["copied"]);
  surface.close();
  frame.key("ctrl+k y");
  equal(frame.copies, ["copied"]);
});

test("a resize changes the frame size and a dispose closes each surface", () => {
  const frame = createFrame({ width: 4, height: 1 });
  const surface = frame.surface("demo");
  frame.resize({ width: 7, height: 3 });
  equal([frame.frame.width, frame.frame.height, frame.frame.cells.length, frame.frame.cells[2]?.length], [7, 3, 3, 7]);
  frame[Symbol.dispose]();
  equal(surface.signal.aborted, true);
});

test("a list of styles merges per field and a later style wins", () => {
  using frame = createFrame({ width: 4, height: 1 });
  const surface = frame.surface("demo");
  surface.tui.styles.set("demo:mark", { fg: 1, bold: true });
  surface.tui.setRoot(() => ({
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
