// The bundled UI shell, built from plugins so a user's index.js layers on top.
import { keymap, Node, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { ui, NAV_KEYS } from "yuke:internal/ui";
import { windowKeys } from "yuke:internal/keys";
import { notice, noticePlugin } from "yuke:internal/notice";
import { commandUi } from "yuke:internal/command-ui";
import { modelCatalog } from "yuke:internal/catalog";
import { jobsUiPlugin } from "yuke:internal/jobs-ui";
import { authPlugin } from "yuke:internal/auth";
import { Session, chatEntry, chatPlugin, currentChat, openSession, showSession } from "yuke:internal/chat";
import { ChatView } from "yuke:internal/chat-view";
import { client } from "yuke:internal/client";
import { attachClipboard } from "yuke:internal/attach";
import { activityMark, feedOf, sessionsPlugin } from "yuke:internal/sessions";
import { activityOf, activityPlugin } from "yuke:internal/activity";
import { indicatorPlugin } from "yuke:internal/indicator";
import { queuePlugin } from "yuke:internal/queue";
import { contextUsage } from "yuke:internal/context";
import { cachePlugin } from "yuke:internal/cache";
import { quitGuard } from "yuke:internal/quit";
/** @import { NavTarget } from "./types/core.js" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Context } from "yuke:internal/ext" */

// The first chat pane. A split adds another, and each pane starts on its own new session.
const chat = new ChatView(new Session());

// Split the focused pane into a new chat. A tree with no active leaf keeps no orphan session.
/** @param {"row" | "col"} kind @returns {void} */
function splitChat(kind) {
  const view = new ChatView(new Session());
  if (!root.split(kind, view)) view.session.leave(view);
}

// Run `fn` on the chat a command acts on. A tree with no chat pane runs nothing.
/** @param {(c: ChatView) => void} fn @returns {void} */
function withChat(fn) {
  const c = currentChat();
  if (c) fn(c);
}

const workspace = Node.leaf(chat);

// A session finder reads the sessions, fuzzy-searches them by title, then opens one; this is the only place the session list appears, so nothing keeps it on screen.
/** @param {InjectContext} ctx @returns {null} */
function openSessionFinder(ctx) {
  const feed = feedOf();
  const show = () => {
    const rows = feed.rows().filter((row) => row.session.origin.type !== "child").sort((a, b) => (b.session.updated_at_ms || 0) - (a.session.updated_at_ms || 0));
    if (rows.length === 0) {
      notice.show("no sessions yet");
      return null;
    }
    const p = ui.pick({
      title: "sessions",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: max => Math.round(max * 0.6),
      height: max => Math.round(max * 0.5),
      items: rows,
      key: r => r.id,
      filterText: r => r.title,
      // An open session reads its live activity; the rest shows what the list reported.
      format: r => ({ text: r.title, right: activityMark(activityOf(r.id) || r.activity) }),
      onAccept: r => {
        const c = currentChat();
        if (c) openSession(c, r.id);
      },
    });
    ctx.tui.overlay(p.win);
    return p;
  };
  feed.refresh().then(show);
  return null;
}

// The stock commands and keybinds ship as a plugin, so they load and unload through the kernel.
plugins.use({
  name: "app-keys",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // Vim calls this showcmd: the keys typed so far, while a chord or an operator waits.
      ctx.tui.status({ side: "right", order: -1, render: () => keymap.pendingLabel() });

      // The interrupt command is available only with a session open.
      ctx.tui.command(() => currentChat()?.session.sessionId != null, {
        "session:interrupt": () => withChat(c => c.session.interrupt()),
      }, {
        "session:interrupt": { title: "Interrupt", description: "stop the run", slash: "interrupt" },
      });

      ctx.tui.command(null, {
        "ui:sessions": () => openSessionFinder(ctx),
        "focus:left": () => root.focusDir("h"),
        "focus:down": () => root.focusDir("j"),
        "focus:up": () => root.focusDir("k"),
        "focus:right": () => root.focusDir("l"),
        "focus:next": () => root.focusCycle(1),
        "focus:prev": () => root.focusCycle(-1),
        "window:split-right": () => splitChat("row"),
        "window:split-down": () => splitChat("col"),
        "window:close": () => root.close(),
        "chat:new": () => withChat(c => {
          showSession(c, new Session());
          root.focusView(c);
        }),
        "chat:paste-image": () => withChat(c => { attachClipboard(c.composer); }),
        "debug:memory": () => {
          const m = client.memoryUsage();
          const mb = (/** @type {number} */ n) => (n / 1048576).toFixed(1) + "MB";
          const k = (/** @type {number} */ n) => Math.round(n / 1000) + "k";
          notice.show("js heap " + mb(m.heap) + " · str " + mb(m.strings) + "/" + k(m.stringCount) +
            " · obj " + mb(m.objects) + "/" + k(m.objectCount) + " · prop " + mb(m.properties) + "/" + k(m.propertyCount) +
            " · shape " + mb(m.shapes) + " · arr " + k(m.arrayCount));
        },
      }, {
        "ui:sessions": { title: "Sessions", description: "open a session", slash: "sessions" },
        "chat:new": { title: "New chat", description: "leave the session and start empty", slash: "new" },
        "chat:paste-image": { title: "Paste image", description: "attach the image on the clipboard" },
      });

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
      ctx.tui.keymap(navKeys);

      ctx.tui.keymap({
        "ctrl+n": "chat:new",
        "ctrl+v": "chat:paste-image",
        "ctrl+f": "ui:sessions",
        "ctrl+c": "session:interrupt",
        "ctrl+q": "quit",
        "ctrl+z": "suspend",
        ...windowKeys("ctrl+k"),
      });
      });
},
});

plugins.use(noticePlugin);
plugins.use(commandUi());
plugins.use(modelCatalog({ entry: chatEntry }));
plugins.use(authPlugin);
plugins.use(jobsUiPlugin);
plugins.use(chatPlugin);
plugins.use(sessionsPlugin);
plugins.use(activityPlugin);
plugins.use(indicatorPlugin);
plugins.use(queuePlugin);
plugins.use(contextUsage());
plugins.use(cachePlugin);
plugins.use(quitGuard);

root.setRoot(workspace);
root.focusView(chat);

export { chat, openSessionFinder };
