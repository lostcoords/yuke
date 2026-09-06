// yuke:defaults — the bundled UI shell, built from plugins so a user's index.js layers on top.
import { keymap, Node, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { ui, NAV_KEYS } from "yuke:ui";
import { notice, noticePlugin } from "yuke:notice";
import { commandUiPlugin } from "yuke:command-ui";
import { explorerPlugin } from "yuke:explorer";
import { catalogPlugin } from "yuke:catalog";
import { Chat, chatEntry, chatPlugin, focusedChat } from "yuke:chat";
import { client } from "yuke:client";
import { rowKey, rowLabel, activityMark, feedOf, sessionsPlugin } from "yuke:sessions";

// The first chat pane. A split adds another, and each pane drives its own session.
const chat = new Chat();

// Split the focused pane into a new chat. A tree with no active leaf keeps no orphan chat.
/** @param {"row" | "col"} kind @returns {void} */
function splitChat(kind) {
  const c = new Chat();
  if (!root.split(kind, c.view)) c.dispose();
}

// Run `fn` on the chat a command acts on. A tree with no chat pane runs nothing.
/** @param {(c: Chat) => void} fn @returns {void} */
function withChat(fn) {
  const c = focusedChat();
  if (c) fn(c);
}

const workspace = new Node(chat.view);

// A session finder: read the sessions, fuzzy-search them by title, then open one.
// This is the only place the session list appears, so nothing keeps it on screen.
/** @param {import("yuke:ext").InjectContext} ctx @returns {null} */
function openSessionFinder(ctx) {
  const feed = feedOf();
  const show = () => {
    const rows = feed.rows().sort((a, b) => (b.session.updated_at_ms || 0) - (a.session.updated_at_ms || 0));
    if (rows.length === 0) {
      notice.show("no sessions yet");
      return null;
    }
    const p = ui.pick({
      title: "sessions",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: 0.6,
      height: 0.5,
      items: rows,
      key: rowKey,
      filterText: r => rowLabel(r),
      format: r => ({ text: rowLabel(r), right: activityMark(r.activity) }),
      onAccept: r => {
        const c = focusedChat();
        if (c) c.open(r.id);
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
  /** @param {import("yuke:ext").InjectContext} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // Vim calls this showcmd: the keys typed so far, while a chord or an operator waits.
      ctx.tui.status({ side: "right", order: -1, render: () => keymap.pendingLabel() });

      // The interrupt command is available only with a session open.
      ctx.tui.command(() => { const c = focusedChat(); return c != null && c.sessionId != null; }, {
        "session:interrupt": () => withChat(c => c.interrupt()),
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
        "chat:new": () => withChat(c => c.newChat()),
        "debug:memory": () => {
          const m = client.memoryUsage();
          const mb = (/** @type {number} */ n) => (n / 1048576).toFixed(1) + "MB";
          const k = (/** @type {number} */ n) => Math.round(n / 1000) + "k";
          notice.show("js heap " + mb(m.heap) + " · str " + mb(m.strings) + "/" + k(m.stringCount) +
            " · obj " + mb(m.objects) + "/" + k(m.objectCount) + " · prop " + mb(m.properties) + "/" + k(m.propertyCount) +
            " · shape " + mb(m.shapes) + " · arr " + k(m.arrayCount));
        },
        "chat:focus-toggle": () => withChat(c => {
          c.view.focusRegion(c.view.focus === "transcript" ? "composer" : "transcript");
          root.invalidate();
        }),
      }, {
        "ui:sessions": { title: "Sessions", description: "open a session", slash: "sessions" },
        "chat:new": { title: "New chat", description: "leave the session and start empty", slash: "new" },
      });

      // Global commands live on ctrl strokes and window nav behind ctrl+k, which leaves ctrl+w for the composer word-erase.
      ctx.tui.keymap({ tab: "chat:focus-toggle" }, "chat");

      // The nav keys drive whichever widget the focused layer offers, so any pane scrolls the same way.
      /** @param {(t: import("yuke:core").NavTarget) => void} fn @returns {() => boolean} */
      const nav = (fn) => () => {
        const target = root.navTarget();
        if (!target) return false;
        fn(target);
        return true;
      };
      /** @type {Record<string, () => boolean>} */
      const navKeys = { "g g": nav((t) => t.navEdge(-1)) };
      for (const stroke in NAV_KEYS) navKeys[stroke] = nav(/** @type {(t: import("yuke:core").NavTarget) => void} */ (NAV_KEYS[stroke]));
      ctx.tui.keymap(navKeys);

      ctx.tui.keymap({
        "ctrl+n": "chat:new",
        "ctrl+f": "ui:sessions",
        "ctrl+c": "session:interrupt",
        "ctrl+q": "quit",
        "ctrl+k h": "focus:left",
        "ctrl+k j": "focus:down",
        "ctrl+k k": "focus:up",
        "ctrl+k l": "focus:right",
        "ctrl+k left": "focus:left",
        "ctrl+k down": "focus:down",
        "ctrl+k up": "focus:up",
        "ctrl+k right": "focus:right",
        "ctrl+k w": "focus:next",
        "ctrl+k v": "window:split-right",
        "ctrl+k s": "window:split-down",
        "ctrl+k c": "window:close",
      });
      });
},
});

plugins.use(noticePlugin);
plugins.use(commandUiPlugin);
plugins.use(explorerPlugin);
plugins.use(catalogPlugin, { entry: chatEntry });
plugins.use(chatPlugin);
plugins.use(sessionsPlugin);

root.setRoot(workspace);
root.focusView(chat.view);

export { workspace, chat, openSessionFinder };
