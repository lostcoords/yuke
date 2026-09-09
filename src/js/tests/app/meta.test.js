import { check, equal } from "yuke:test";
import { command, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { commandUiPlugin } from "yuke:command-ui";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
plugins.use(commandUiPlugin);

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
check("palette-shows-meta", p.selectKey("test:shown") && p.selected().description === "the last one");
check("palette-hides-plumbing", !p.selectKey("test:plumbing"));
check("palette-hides-itself", !p.selectKey("ui:palette"));
root.popOverlay();
off();
