// The bundled TUI app: each part is its own plugin, so a user's index.js disposes or replaces one without the others.
import { keymap, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { NAV_KEYS } from "yuke:internal/ui";
import { noticePlugin } from "yuke:internal/notice";
import { commandUi } from "yuke:internal/command-ui";
import { catalogPlugin } from "yuke:internal/catalog";
import { jobsUiPlugin } from "yuke:internal/jobs-ui";
import { authPlugin } from "yuke:internal/auth";
import { chatPlugin } from "yuke:internal/chat";
import { sessionsPlugin } from "yuke:internal/session";
import { indicatorPlugin } from "yuke:internal/indicator";
import { queuePlugin } from "yuke:internal/queue";
import { contextUsage } from "yuke:internal/context";
import { cachePlugin } from "yuke:internal/cache";
import { quitGuard } from "yuke:internal/quit";
import { shell } from "yuke:internal/shell";
/** @import { NavTarget } from "./types/core.js" */
/** @import { Context } from "yuke:internal/ext" */

// The default keys: scrolling for whatever has the focus, the keys typed so far, and quit and suspend.
const keysPlugin = {
  name: "keys",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // Vim calls this showcmd: the keys typed so far, while a chord or an operator waits.
      ctx.tui.status.add({ side: "right", order: -1, render: () => keymap.pendingLabel() });

      // The nav keys drive whichever widget the focused layer offers, so any pane scrolls the same way.
      /** @param {(t: NavTarget) => void} fn @returns {() => boolean} */
      const nav = (fn) => () => {
        const target = root.navTarget();
        if (!target) return false;
        fn(target);
        return true;
      };
      /** @type {Record<string, () => boolean>} */
      const navKeys = { "g g": nav((t) => t.navEdge(-1)) };
      for (const stroke in NAV_KEYS) navKeys[stroke] = nav(/** @type {(t: NavTarget) => void} */ (NAV_KEYS[stroke]));
      ctx.tui.keymap.add(navKeys);
      ctx.tui.keymap.add({ "ctrl+q": "quit", "ctrl+z": "suspend" });
    });
  },
};

plugins.use(keysPlugin);
plugins.use(noticePlugin);
plugins.use(commandUi());
plugins.use(catalogPlugin);
plugins.use(authPlugin);
plugins.use(jobsUiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
plugins.use(indicatorPlugin);
plugins.use(queuePlugin);
plugins.use(contextUsage());
plugins.use(cachePlugin);
plugins.use(quitGuard);
plugins.use(shell);
