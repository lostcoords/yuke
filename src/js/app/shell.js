// The window manager: the first pane, splits, focus, close, and the window keys. A new pane asks the chat service for its view.
import { Node, root } from "yuke:internal/core";
import { windowKeys } from "yuke:internal/keys";

/** @import { Context } from "yuke:internal/ext" */

export const shell = {
  name: "shell",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    // A new provider builds the next tree before the old block leaves, so only the newest block clears the root.
    let mounted = 0;
    ctx.inject(["tui", "chat"], (ctx) => {
      const build = ++mounted;
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
      return () => { if (build === mounted) root.setRoot(null); };
    });
  },
};
