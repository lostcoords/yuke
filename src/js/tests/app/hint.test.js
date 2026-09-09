import { check } from "yuke:test";
import { command, keymap, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { commandUiPlugin } from "yuke:command-ui";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
plugins.use(commandUiPlugin);

const meta = { title: "t", description: "d" };
const offCmd = command.add(null, {
  "test:plain": () => {}, "test:hidden": () => {},
  "test:shadowed": () => {}, "test:winner": () => {},
}, { "test:plain": meta, "test:hidden": meta, "test:shadowed": meta, "test:winner": meta });
const offA = keymap.add({ "ctrl+alt+a": "test:plain" });
// No pane provides this atom, so the stroke never reaches the command.
const offB = keymap.add({ "ctrl+alt+b": "test:hidden" }, "no_such_pane");
// One stroke, two commands: the newest entry answers it and the older one is shadowed.
const offC = keymap.add({ "ctrl+alt+c": "test:shadowed" });
const offD = keymap.add({ "ctrl+alt+c": "test:winner" });

const hintOf = (name) => {
  command.perform("ui:palette");
  const win = root.overlays[root.overlays.length - 1];
  const p = win.content;
  p.selectKey(name);
  const it = p.selected();
  root.popOverlay(win);
  return it && it.name === name ? it.hint : null;
};

check("hint-shows-active", hintOf("test:plain") === "ctrl+alt+a");
check("hint-hides-inactive", hintOf("test:hidden") === "");
check("hint-shows-winner", hintOf("test:winner") === "ctrl+alt+c");
check("hint-hides-shadowed", hintOf("test:shadowed") === "");
check("palette-closed", root.overlays.length === 0);

offA(); offB(); offC(); offD(); offCmd();
