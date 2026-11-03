import { createFrame, createHost, equal, test } from "yuke:test";
import * as nord from "../snippets/themes/nord.ts";
import * as aware from "../snippets/themes/theme-aware.ts";
import { withSurface } from "./context.ts";

test("the documented theme colors text when selected and unload restores the default", async () => {
  using frame = createFrame({ width: 20, height: 2 });
  const tui = frame.surface("observer").tui;
  await using host = await createHost({
    plugins: [{ name: "nord", apply: (ctx) => nord.apply(withSurface(ctx, frame.surface("nord"))) }],
  });
  tui.setRoot(() => ({ draw: (canvas) => canvas.text(0, 0, "accent", { fg: "accent" }) }));
  tui.styles.setTheme("nord");
  const selected = frame.draw().cells[0]?.[0]?.style.fg;
  await host.close();
  equal([selected, frame.draw().cells[0]?.[0]?.style.fg], ["#88c0d0", "#a8cfa0"]);
});

test("the documented theme listener changes its group on each theme selection", async () => {
  using frame = createFrame({ width: 20, height: 2 });
  const tui = frame.surface("observer").tui;
  await using host = await createHost({
    plugins: [
      { name: "nord", apply: (ctx) => nord.apply(withSurface(ctx, frame.surface("nord"))) },
      { name: "aware", apply: (ctx) => aware.apply(withSurface(ctx, frame.surface("aware"))) },
    ],
  });
  tui.setRoot(() => ({ draw: (canvas) => canvas.text(0, 0, "note", "notes.title") }));
  tui.styles.setTheme("nord");
  const selected = frame.draw().cells[0]?.[0]?.style.fg;
  tui.styles.setTheme("default");
  equal([selected, frame.draw().cells[0]?.[0]?.style.fg, host.notices], ["#ebcb8b", undefined, []]);
});
