import { assertEquals, createFrame, createHost, test } from "yuke:test";
import * as nord from "../snippets/themes/nord.ts";
import * as aware from "../snippets/themes/theme-aware.ts";

test("the documented theme colors text when selected and unload restores the default", async () => {
  using frame = createFrame({ width: 20, height: 2 });
  const tui = frame.surface("observer").tui;
  await using host = await createHost({
    frame,
    plugins: [{ name: "nord", ...nord }],
  });
  tui.wrapRoot(() => ({ draw: (canvas) => canvas.text(0, 0, "accent", { fg: "accent" }) }));
  tui.styles.setTheme("nord");
  const selected = frame.draw().cells[0]?.[0]?.style.fg;
  await host.close();
  assertEquals([selected, frame.draw().cells[0]?.[0]?.style.fg], ["#88c0d0", "#a8cfa0"]);
});

test("the documented theme listener changes its group on each theme selection", async () => {
  using frame = createFrame({ width: 20, height: 2 });
  const tui = frame.surface("observer").tui;
  await using host = await createHost({
    frame,
    plugins: [
      { name: "nord", ...nord },
      { name: "aware", ...aware },
    ],
  });
  tui.wrapRoot(() => ({ draw: (canvas) => canvas.text(0, 0, "note", "notes.title") }));
  tui.styles.setTheme("nord");
  const selected = frame.draw().cells[0]?.[0]?.style.fg;
  tui.styles.setTheme("default");
  assertEquals([selected, frame.draw().cells[0]?.[0]?.style.fg, host.notices], ["#ebcb8b", undefined, []]);
});
