import { check, equal } from "yuke:internal/test";
import { command, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { commandUi } from "yuke:internal/command-ui";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
plugins.use(commandUi());

// The palette shows the slash word, or the name, so the list sorts by that word and a prefix sorts before a longer word.
const offs = [
  command.add("test:shown", { desc: "the last one", slash: "opencode-responses", run: () => {} }),
  command.add("test:plumbing", { run: () => {} }),
  command.add("test:first", { desc: "the first one", slash: "minimax", run: () => {} }),
  command.add("test:prefix", { desc: "the middle one", slash: "opencode", run: () => {} }),
];
const off = () => { for (const o of offs) o(); };
const listed = command.list().map((c) => c.name);
check("list-skips-plumbing", listed.indexOf("test:plumbing") < 0);
equal(listed.filter(name => name.startsWith("test:")).join(","), "test:first,test:prefix,test:shown");

command.perform("ui:palette");
const p = root.overlays[root.overlays.length - 1].content;
check("palette-shows-meta", p.list.selectKey("test:shown") && p.list.selected().desc === "the last one");
check("palette-hides-plumbing", !p.list.selectKey("test:plumbing"));
check("palette-hides-itself", !p.list.selectKey("ui:palette"));
root.popOverlay();
off();
