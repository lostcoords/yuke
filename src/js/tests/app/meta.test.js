import { check, equal } from "yuke:internal/test";
import { command, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { commandUi } from "yuke:internal/command-ui";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
plugins.use(commandUi());

const off = command.add(null, { "test:shown": () => {}, "test:plumbing": () => {}, "test:first": () => {}, "test:prefix": () => {} }, {
  "test:shown": { title: "opencode-responses", description: "the last one" },
  "test:first": { title: "minimax", description: "the first one" },
  "test:prefix": { title: "opencode", description: "the middle one" },
});
const listed = command.list().map((c) => c.name);
check("list-skips-plumbing", listed.indexOf("test:plumbing") < 0);
equal(listed.filter(name => name.startsWith("test:")).join(","), "test:first,test:prefix,test:shown");

command.perform("ui:palette");
const p = root.overlays[root.overlays.length - 1].content;
check("palette-shows-meta", p.list.selectKey("test:shown") && p.list.selected().description === "the last one");
check("palette-hides-plumbing", !p.list.selectKey("test:plumbing"));
check("palette-hides-itself", !p.list.selectKey("ui:palette"));
root.popOverlay();
off();
