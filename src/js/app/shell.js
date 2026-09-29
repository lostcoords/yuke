// The window manager: the first pane, splits, focus, close, and the window keys. A new pane asks the chat service for its view.
import { Node, root } from "yuke:internal/core";
import { windowKeys } from "yuke:internal/keys";

/** @import { Context } from "yuke:internal/ext" */

/**
 * The `shell` plugin: the window manager. It shows the first chat pane and adds the focus, split, and close commands under the ctrl+k leader.
 * It needs the `tui` and `chat` capabilities. An unload closes every pane.
 */
export const shell = {
  name: "shell",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui", "chat"], (ctx) => {
      root.setRoot(Node.leaf(ctx.chat.create()));

      // A split shows a new chat; a tree with no focused pane keeps no orphan session.
      /** @param {"row" | "col"} kind @returns {void} */
      const split = (kind) => {
        const view = ctx.chat.create();
        if (!root.split(kind, view)) view.session.leave(view);
      };

      // Window commands are keymap targets, so they carry no description and never list.
      ctx.tui.command.add("focus:left", { run: () => root.focusDir("h") });
      ctx.tui.command.add("focus:down", { run: () => root.focusDir("j") });
      ctx.tui.command.add("focus:up", { run: () => root.focusDir("k") });
      ctx.tui.command.add("focus:right", { run: () => root.focusDir("l") });
      ctx.tui.command.add("focus:next", { run: () => root.focusCycle(1) });
      ctx.tui.command.add("focus:prev", { run: () => root.focusCycle(-1) });
      ctx.tui.command.add("window:split-right", { run: () => split("row") });
      ctx.tui.command.add("window:split-down", { run: () => split("col") });
      ctx.tui.command.add("window:close", { run: () => root.close() });
      ctx.tui.keymap.add(windowKeys("ctrl+k"));

      // The unload closes every pane, and each chat view releases its session.
      return () => root.setRoot(null);
    });
  },
};
