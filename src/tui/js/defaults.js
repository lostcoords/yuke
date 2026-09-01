// yuke:defaults — the bundled UI shell, built from plugins so a user's index.js layers on top.
import { keymap, copy, clip, text, Node, root, quit, config } from "yuke:core";
import { plugins } from "yuke:ext";
import { ui, NAV_KEYS } from "yuke:ui";
import * as client from "yuke:client";
import { noticePlugin } from "yuke:notice";
import { commandUiPlugin } from "yuke:command-ui";
import { explorerPlugin } from "yuke:explorer";
import { catalogOf, catalogPlugin } from "yuke:catalog";
import { Chat, chatEntry, chatPlugin, focusedChat } from "yuke:chat";
import { SessionList, DeviceFeed, rowKey, rowLabel, activityMark, sidebarPlugin } from "yuke:sidebar";
import { composerVim } from "yuke:composer-vim";
import { transcriptVim } from "yuke:transcript-vim";

/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_usage: Wire.TokenUsage, pending_compaction: null }} FeedActivity */
/** @typedef {{ is_self?: boolean, static_public_key?: string, device_id: string, online?: boolean, name?: string }} DeviceInfo */
/** @typedef {{ nextRetryAt: number, remoteRetryAt: Record<string, number>, roster: DeviceInfo[], rosterTried: boolean, stopped: boolean, onStart: () => void, onStop: () => void, attempt: () => void, dialLocal: () => void, loadRoster: () => void, dialableKey: (d: DeviceInfo) => string | null, dialRemotes: () => void, scheduleRetry: () => void, needsTick: () => { periodMs: number } | null, tick: () => void }} ConnectionService */


// The sidebar's share of the width in the default row split.
const SIDEBAR_RATIO = 0.28;

// The local conn key. A remote is `remote:<device_id>`. An empty `devices()` means no relay.
const LOCAL = client.LOCAL;






// --- default layout -----------------------------------------------------------------------






// Enter previews the session and stays on the list, while click, `l`, and → move into the chat.
/** @param {string} connKey @returns {string} */
function deviceName(connKey) {
  if (connKey === LOCAL) return "local";
  if (connKey.indexOf("remote:") !== 0) return "";
  const id = connKey.slice("remote:".length);
  const d = connection.roster.find((x) => x.device_id === id);
  return (d && d.name) || id.slice(0, 7);
}

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

const sidebar = new SessionList({
  statusLabel: connectionLabel,
  activeSession: () => {
    const c = focusedChat();
    return c && c.sessionId ? { connKey: c.connKey, sessionId: c.sessionId } : null;
  },
  onOpen: (connKey, id, src) => {
    const c = focusedChat();
    if (!c) return;
    c.open(connKey, id);
    if (src !== "key") root.focusView(c.view);
  },
});

const workspace = Node.branch("row", new Node(sidebar), new Node(chat.view), SIDEBAR_RATIO);




// A session finder: fuzzy-search the sidebar's loaded sessions by title, then open one.
function openSessionFinder() {
  return ui.pick({
    title: "sessions",
    footer: "type to filter · ↵ select · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.5,
    items: sidebar.list.items,
    key: rowKey,
    filterText: r => rowLabel(r),
    format: r => ({ text: rowLabel(r), right: activityMark(r.activity) }),
    onAccept: r => {
      sidebar.list.selectedKey = rowKey(r);
      const c = focusedChat();
      if (c) c.open(r.connKey, r.id);
    },
  });
}




// --- daemon connection --------------------------------------------------------------------
// The retry tick repaints the sidebar countdown, which changes once per second.
const RETRY_POLL_MS = 1000;

const NO_RETRY = {
  device_not_found: true,
  device_ambiguous: true,
  not_enrolled: true,
  identity_unreadable: true,
};

/** @type {ConnectionService} */
const connection = {
  nextRetryAt: 0,
  remoteRetryAt: Object.create(null),
  roster: [],
  rosterTried: false,
  // A settled dial must do nothing once the owner unloads, so every callback reads this.
  stopped: false,

  onStart() {
    this.stopped = false;
    if (config.daemon.autoConnect === false) return;
    this.attempt();
  },

  // An unload drops the connections this service opened and disarms its pending callbacks.
  onStop() {
    this.stopped = true;
    this.nextRetryAt = 0;
    this.remoteRetryAt = Object.create(null);
    this.roster = [];
    this.rosterTried = false;
    for (const c of client.connections()) client.disconnect(c.key);
  },

  attempt() {
    if (this.stopped) return;
    this.dialLocal();
    this.loadRoster();
    this.dialRemotes();
    root.invalidate();
  },

  dialLocal() {
    if (this.stopped) return;
    if (client.connectionState(LOCAL) !== "disconnected") return;
    this.nextRetryAt = 0;
    const opts = { host: config.daemon.host, port: config.daemon.port };
    try {
      client.connect(opts).then(
        () => {
          if (!this.stopped) root.invalidate();
        },
        () => {
          if (this.stopped) return;
          this.scheduleRetry();
          root.invalidate();
        },
      );
    } catch (_e) {
      this.scheduleRetry();
    }
  },

  loadRoster() {
    if (this.stopped || this.rosterTried) return;
    this.rosterTried = true;
    client.devices().then(
      (devs) => {
        if (this.stopped) return;
        this.roster = /** @type {DeviceInfo[]} */ (devs || []);
        this.dialRemotes();
        root.invalidate();
      },
      () => {
        if (!this.stopped) this.roster = [];
      },
    );
  },

  // Return the key of a remote to dial, including one that still waits for its retry time.
  /** @param {DeviceInfo} d @returns {string | null} */
  dialableKey(d) {
    if (!d || d.is_self || !d.static_public_key) return null;
    const key = "remote:" + d.device_id;
    if (client.connectionState(key) !== "disconnected") return null;
    if (!d.online && !this.remoteRetryAt[key]) return null;
    return key;
  },

  dialRemotes() {
    if (this.stopped || config.daemon.autoConnect === false) return;
    const now = Date.now();
    for (const d of this.roster) {
      const key = this.dialableKey(d);
      if (!key) continue;
      if (this.remoteRetryAt[key] && now < this.remoteRetryAt[key]) continue;
      this.remoteRetryAt[key] = 0;
      try {
        client.connect({ remote: true, device: d.device_id }).then(
          () => {
            if (!this.stopped) root.invalidate();
          },
          (err) => {
            if (this.stopped) return;
            const code = err && err.code;
            if ((/** @type {Record<string, boolean>} */ (NO_RETRY))[code]) return;
            this.remoteRetryAt[key] = Date.now() + config.daemon.retryMs;
            root.invalidate();
          },
        );
      } catch (_e) {
        // a connect attempt is active
      }
    }
  },

  scheduleRetry() {
    if (config.daemon.autoConnect === false) return;
    this.nextRetryAt = Date.now() + config.daemon.retryMs;
  },

  // Ask for a tick only while a connection attempt or a retry stays open.
  needsTick() {
    if (this.stopped || config.daemon.autoConnect === false) return null;
    if (client.connectionState(LOCAL) === "disconnected") return { periodMs: RETRY_POLL_MS };
    for (const d of this.roster) {
      if (this.dialableKey(d)) return { periodMs: RETRY_POLL_MS };
    }
    return null;
  },

  tick() {
    if (this.stopped || config.daemon.autoConnect === false) return;
    if (client.connectionState(LOCAL) === "disconnected") {
      if (this.nextRetryAt === 0) this.scheduleRetry();
      else if (Date.now() >= this.nextRetryAt) this.dialLocal();
    }
    this.dialRemotes();
  },
};

// The sidebar status line: a local-only copy alone, or a count once remotes exist.
function connectionLabel() {
  const list = client.connections();
  const ready = list.filter((c) => c.state === "ready");
  if (ready.length > 1) return ready.length + " connected";
  if (ready.length === 1) {
    const conn = /** @type {NonNullable<(typeof ready)[number]>} */ (ready[0]);
    return conn.key === LOCAL
      ? "local · connected"
      : conn.key + " · connected";
  }
  const st = client.connectionState(LOCAL);
  if (st === "connecting") return "local · connecting…";
  if (st === "closing") return "local · disconnecting…";
  if (connection.nextRetryAt > 0) {
    const secs = Math.max(0, Math.ceil((connection.nextRetryAt - Date.now()) / 1000));
    return "local · off · retry " + secs + "s";
  }
  return "local · off";
}

// --- commands + keymaps -------------------------------------------------------------------
// The stock commands and keybinds ship as a plugin, so they load and unload through the kernel.
plugins.use({
  name: "app-keys",
  /** @param {import("yuke:ext").Context} ctx */
  apply(ctx) {
    // Vim calls this showcmd: the keys typed so far, while a chord or an operator waits.
    ctx.status({ side: "right", order: -1, render: () => keymap.pendingLabel() });

    // The interrupt command is available only with a session open.
    ctx.command(() => { const c = focusedChat(); return c != null && c.sessionId != null; }, {
      "session:interrupt": () => withChat(c => c.interrupt()),
    });

    ctx.command(null, {
      "app:quit": () => quit(),
      "ui:sessions": () => ctx.overlay(openSessionFinder().win),
      "app:connect": () => connection.attempt(),
      "focus:left": () => root.focusDir("h"),
      "focus:down": () => root.focusDir("j"),
      "focus:up": () => root.focusDir("k"),
      "focus:right": () => root.focusDir("l"),
      "focus:next": () => root.focusCycle(1),
      "focus:prev": () => root.focusCycle(-1),
      "window:split-right": () => splitChat("row"),
      "window:split-down": () => splitChat("col"),
      "window:close": () => root.close(),
      "copy:reply": () => withChat(c => copy(c.transcript.textFor(c.transcript.last("assistant")), "reply")),
      "copy:selection": () => withChat(c => copy(c.transcript.selectedText(), "selection")),
      "copy:source": () => withChat(c => copy(c.transcript.selectedSource(), "source")),
      "chat:new": () => withChat(c => c.newChat()),
      "chat:focus-toggle": () => withChat(c => {
        c.view.focusRegion(c.view.focus === "transcript" ? "composer" : "transcript");
        root.invalidate();
      }),
      "composer-vim:toggle": () => (plugins.get("composer-vim") ? plugins.dispose("composer-vim") : plugins.use(composerVim)),
      "transcript-vim:toggle": () => (plugins.get("transcript-vim") ? plugins.dispose("transcript-vim") : plugins.use(transcriptVim)),
    });

    // Global commands live on ctrl strokes and window nav behind ctrl+k, which leaves ctrl+w for the composer word-erase.
    ctx.keymap({ tab: "chat:focus-toggle" }, "chat");

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
    ctx.keymap(navKeys);

    ctx.keymap({
      "ctrl+n": "chat:new",
      "ctrl+f": "ui:sessions",
      "ctrl+c": "session:interrupt",
      "ctrl+q": "app:quit",
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
  },
});

plugins.use(noticePlugin);
plugins.use(commandUiPlugin);
plugins.use(explorerPlugin);
plugins.use(catalogPlugin, { entry: chatEntry, connKey: () => { const c = focusedChat(); return c ? c.connKey : LOCAL; } });
plugins.use(chatPlugin);
plugins.use(sidebarPlugin, { deviceName, onCatalogChanged: /** @param {string} connKey @returns {void} */ (connKey) => { catalogOf(connKey).rev = null; } });

plugins.use({
  name: "connection",
  /** @param {import("yuke:ext").Context} ctx */
  apply(ctx) {
    ctx.service(connection);
  },
});

root.setRoot(workspace);
root.focusView(chat.view);

export { workspace, sidebar, chat, SessionList, DeviceFeed, openSessionFinder, connection };
