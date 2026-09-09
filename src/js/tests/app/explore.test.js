import { check } from "yuke:test";
import { fs } from "yuke:fs";
import { command, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { explorerPlugin } from "yuke:explorer";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
plugins.use(explorerPlugin);

let asked = "unset";
fs.list = (path) => {
  asked = path;
  return Promise.resolve({
    path: "/w", parent: "/", more: true,
    entries: [{ name: "a", path: "/w/a", is_git_repo: true }, { name: "b", path: "/w/b", is_git_repo: false }],
  });
};
command.perform("app:explorer");
await Promise.resolve();
const rows = root.overlays[root.overlays.length - 1].content.list.items;
check("lists-the-working-directory", asked === null);
// A parent leads the page, the entries follow, and `more` adds the truncation notice.
check("parent-row-first", rows[0].up === true && rows[0].dest === "/");
check("entry-rows", rows[1].path === "/w/a" && rows[1].is_git_repo === true && rows[2].path === "/w/b");
check("more-adds-notice", rows[3].notice === true && rows.length === 4);

// A refusal replaces the page with one notice instead of leaving the old rows.
fs.list = () => Promise.reject(new Error("unreadable"));
root.overlays[root.overlays.length - 1].content.keymap.left();
await Promise.resolve();
await Promise.resolve();
const after = root.overlays[root.overlays.length - 1].content.list.items;
check("refusal-shows-one-notice", after.length === 1 && after[0].notice === true);
