// yuke:explorer — a filesystem picker that walks directories and reports the chosen path.
import { root } from "yuke:core";
import { ui } from "yuke:ui";
import * as client from "yuke:client";

const LOCAL = client.LOCAL;

/** @typedef {{ key: string, notice: true, text: string, up?: never, dest?: never, name?: never, path?: never, is_git_repo?: never } | { key: string, up: true, dest: string, notice?: never, text?: never, name?: never, path?: never, is_git_repo?: never } | { key: string, name: string, path: string, is_git_repo?: boolean, notice?: never, up?: never, dest?: never, text?: never }} ExplorerRow */

// A floating directory navigator over the fs.browse RPC, fuzzy-filtered as you type.
// Enter/→ descends; ← goes to the parent; Esc closes.
/** @param {string | null | undefined} [startPath] */
function openExplorer(startPath) {
  const state = /** @type {{ path: string, parent: string | null | undefined }} */ ({ path: startPath || "", parent: null });

  const picker = ui.pick({
    title: () => state.path || "…",
    footer: "type to filter · ↵/→ enter · ← up · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.6,
    key: e => e.key,
    filterText: e => e.name || "",
    isSelectable: e => !e.notice,
    format: e => {
      if (e.notice) return { text: e.text, group: "UIDim" };
      if (e.up) return { text: "..", group: "UIDim" };
      return { text: e.name + "/", right: e.is_git_repo ? "git" : "" };
    },
    onAccept: e => {
      if (e.notice) return;
      go(e.up ? e.dest : e.path);
    },
    closeOnAccept: false,
    keymap: {
      left: () => {
        if (state.parent != null) go(state.parent);
      },
      right: (_ev, p) => {
        const e = p.selected();
        if (e && !e.up && !e.notice) go(e.path);
      },
    },
  });

  /** @param {string | null | undefined} path */
  function go(path) {
    client.fsBrowse(LOCAL, path != null ? { path } : {}).then(
      (res) => {
        state.path = res.path;
        state.parent = res.parent;

        /** @type {ExplorerRow[]} */
        const rows = [];
        if (res.parent != null) rows.push({ key: "..", up: true, dest: res.parent });
        for (const e of res.entries) {
          rows.push({ key: e.path, name: e.name, path: e.path, is_git_repo: e.is_git_repo });
        }
        if (res.next_cursor != null) rows.push({ key: "\x00more", notice: true, text: "… more entries not shown" });

        const content = picker.content;
        content.query = "";
        content.setSource(rows);
        root.invalidate();
      },
      () => {
        const content = picker.content;
        content.query = "";
        content.setSource([{ key: "\x00err", notice: true, text: "cannot browse — daemon offline?" }]);
        root.invalidate();
      },
    );
  }

  go(state.path || null);
  return picker;
}

// The command that opens the picker; the context owns the overlay, so an unload takes it away.
export const explorerPlugin = {
  name: "explorer",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.command(null, {
      "app:explorer": () => {
        const picker = openExplorer();
        ctx.overlay(picker.win);
        return picker;
      },
    });
  },
};
