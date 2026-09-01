// yuke:defaults — the bundled UI: a sidebar | chat split shell with a local connect, a command
// palette, a ":" line, and a stub explorer. A user's index.js layers on top.
import { term } from "yuke:term";
import { command, keymap, status, copy, clip, fill, text, strokeOf, TextInput, caretCol, Node, root, quit, config, events } from "yuke:core";
import { plugins } from "yuke:ext";
import { ui, ChatView, List, NAV_KEYS } from "yuke:ui";
import * as client from "yuke:client";
import { notice, noticePlugin } from "yuke:notice";
import { commandUiPlugin } from "yuke:command-ui";
import { SessionList, DeviceFeed, rowKey, rowLabel, activityMark, feedItem, newestLocalModelSession, sidebarPlugin } from "yuke:sidebar";
import { composerVim } from "yuke:composer-vim";
import { transcriptVim } from "yuke:transcript-vim";

/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_usage: Wire.TokenUsage, pending_compaction: null }} FeedActivity */
/** @typedef {{ session: Wire.Session, activity: FeedActivity }} FeedItem */
/** @typedef {{ connKey: string, id: string, title: string, activity: FeedActivity, session: Wire.Session, workspace: Wire.Workspace | null, deviceName: string }} SessionRow */
/** @typedef {{ method: string, params: any }} BroadcastEvent */
/** @typedef {{ onOpen?: (connKey: string, id: string, src: string) => void }} SessionListOptions */
/** @typedef {{ rev: Wire.CatalogRev | null, models: readonly Wire.ModelInfo[], providers: readonly Wire.ProviderInfo[], loading: boolean }} CatalogState */
/** @typedef {{ model: string | null, reasoning: string }} ModelDefaults */
/** @typedef {{ workspace_path?: string, profile?: string, model?: string, reasoning?: string, system_prompt?: string, permission?: Wire.PermissionMode, max_rounds?: number }} CreateSessionDraft */
/** @typedef {{ is_self?: boolean, static_public_key?: string, device_id: string, online?: boolean, name?: string }} DeviceInfo */
/** @typedef {{ key: string, notice: true, text: string, up?: never, dest?: never, name?: never, path?: never, is_git_repo?: never } | { key: string, up: true, dest: string, notice?: never, text?: never, name?: never, path?: never, is_git_repo?: never } | { key: string, name: string, path: string, is_git_repo?: boolean, notice?: never, up?: never, dest?: never, text?: never }} ExplorerRow */
/** @typedef {{ m: { id: number, type: string }, i: number, text: string }} MessagePickerItem */
/** @typedef {{ id: number, lang: string, text: string, i: number }} CodeBlockRow */
/** @typedef {{ connKey: string, sessionId: string | null, creating: boolean, gen: number, open: (connKey: string, id?: string | null) => void, send: (text: string) => boolean, interrupt: () => void, reload: () => void, active: (id: number) => void, startChat: (text: string) => boolean, newChat: () => void, close: () => void }} ChatSession */
/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "session" }>} NativeSessionEvent */
/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "index" }>} NativeIndexEvent */
/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "conn" }> & { workspaces?: readonly Wire.Workspace[] }} NativeConnEvent */
/** @typedef {{ nextRetryAt: number, remoteRetryAt: Record<string, number>, roster: DeviceInfo[], rosterTried: boolean, stopped: boolean, onStart: () => void, onStop: () => void, attempt: () => void, dialLocal: () => void, loadRoster: () => void, dialableKey: (d: DeviceInfo) => string | null, dialRemotes: () => void, scheduleRetry: () => void, needsTick: () => { periodMs: number } | null, tick: () => void }} ConnectionService */

// The ":" command line: the prompt links to Normal; an unmatched word shows in red.

// The sidebar's share of the width in the default row split.
const SIDEBAR_RATIO = 0.28;

// The local conn key. A remote is `remote:<device_id>`. An empty `devices()` means no relay.
const LOCAL = client.LOCAL;


// One catalog per connection. `catalog.list` answers "unchanged" while the revision holds, so a
// reopened picker costs no round trip.
/** @type {Map<string, CatalogState>} */
const catalogs = new Map();

/** @param {string} connKey @returns {CatalogState} */
function catalogOf(connKey) {
  let c = catalogs.get(connKey);
  if (!c) {
    c = { rev: null, models: [], providers: [], loading: false };
    catalogs.set(connKey, c);
  }
  return c;
}

/** @param {string} connKey @returns {Promise<CatalogState>} */
function loadCatalog(connKey) {
  const c = catalogOf(connKey);
  if (c.loading) return Promise.resolve(c);
  c.loading = true;
  return client
    .catalogList(connKey, c.rev)
    .then((r) => {
      if (r && r.type === "full") {
        c.rev = r.catalog_rev;
        c.models = r.models || [];
        c.providers = r.providers || [];
      }
    })
    .catch(() => {})
    .then(() => {
      c.loading = false;
      root.invalidate();
      return c;
    });
}

// The context window of one model, or 0 when the catalog does not name it.
/** @param {string} connKey @param {string | null | undefined} modelId @returns {number} */
function contextWindowOf(connKey, modelId) {
  if (!modelId) return 0;
  const m = catalogOf(connKey).models.find((x) => x.selector === modelId);
  return m && m.context_window ? m.context_window : 0;
}

// The model a new chat starts with. `session.patch` is not implemented, so a choice cannot move an
// open session yet.
/** @type {ModelDefaults} */
const chatDefaults = { model: null, reasoning: "" };

/** @param {Wire.ModelInfo} model @param {string} reasoning @returns {void} */
function chooseModel(model, reasoning) {
  chatDefaults.model = model.selector;
  chatDefaults.reasoning = reasoning;
  notice.show("model · " + model.name + (reasoning ? " · " + reasoning : ""));
  root.invalidate();
}

// Without a choice this run, the newest session names the model and reasoning, so a restart keeps working.
/** @returns {ModelDefaults} */
function defaultModel() {
  if (chatDefaults.model) return chatDefaults;
  const s = newestLocalModelSession();
  if (s && s.model) return { model: s.model, reasoning: s.reasoning };
  return chatDefaults;
}

/** @param {string} text @returns {void} */
function restoreInput(text) {
  const now = chat.composer.text;
  chat.composer.text = now === "" ? text : text + "\n" + now;
}

// The chat's live entry, or null with no open session.
/** @returns {FeedItem | null} */
function chatEntry() {
  if (!chatSession.sessionId) return null;
  return feedItem(chatSession.connKey, chatSession.sessionId);
}

// Round a token count to a short label. The catalog is not in the TUI, so this is not a percentage.
/** @param {number} n @returns {string} */
function tokenLabel(n) {
  if (n < 1000) return String(n);
  return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
}

// Vim calls this showcmd: the keys typed so far, while a chord or an operator waits.
status.add({ side: "right", order: -1, render: () => keymap.pendingLabel() });
status.add({
  side: "right",
  order: 10,
  render: () => {
    const e = chatEntry();
    if (e && e.session && e.session.model) return e.session.model;
    return defaultModel().model || "";
  },
});
status.add({
  side: "right",
  order: 20,
  render: () => {
    const e = chatEntry();
    if (!e) return "";
    const u = e && e.activity ? e.activity.context_usage : null;
    if (!u || !u.input) return "";
    const win = contextWindowOf(chatSession.connKey, e.session.model);
    return win ? Math.round((u.input / win) * 100) + "% ctx" : tokenLabel(u.input) + " ctx";
  },
});

// The main pane: a placeholder shown in a split leaf with no session.
class MainPane {
  constructor() {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  get name() {
    return "main";
  }

  /** @param {HostEvent} _ev @returns {boolean} */
  onKey(_ev) {
    return false;
  }

  /** @param {boolean} _focused @returns {void} */
  draw(_focused) {
    const { x, y, w: mw, h } = this.rect;
    if (mw <= 0 || h <= 0) return;

    const pad = mw >= 4 ? 1 : 0;
    const iw = Math.max(0, mw - pad * 2);
    const st = client.connectionState(LOCAL);

    let msg;
    if (st !== "ready") {
      msg = st === "connecting" ? "connecting to local daemon…" : "daemon offline — :connect to retry";
    } else {
      msg = "select a session";
    }

    const bodyH = Math.max(0, h - 1);
    const cy = y + Math.floor(Math.max(0, bodyH - 1) / 2);
    if (bodyH > 0) text(x + pad, cy, clip(msg, iw), "YukeEmpty");
    if (h > 0) text(x + pad, y + h - 1, clip("^p palette · ^k h/l pane", iw), "YukeFooter");
  }
}

// --- default layout -----------------------------------------------------------------------
const newChatLines = () => {
  const m = defaultModel().model;
  return [
    { text: "new chat", group: "YukeBrand" },
    { text: m ? "model · " + m : "no model yet · :model:pick", group: "YukeEmpty" },
    { text: "type a message to start the session", group: "YukeEmpty" },
  ];
};

const chat = new ChatView({
  textOf: id => (chatSession.sessionId ? client.sessionText(chatSession.connKey, chatSession.sessionId, id) : ""),
  partsOf: id => (chatSession.sessionId ? client.sessionParts(chatSession.connKey, chatSession.sessionId, id) : []),
  onSubmit: text => chatSession.send(text),
  onSelect: text => {
    if (config.mouse.copyOnSelect) copy(text, "selection");
  },
  empty: () => (chatSession.sessionId ? null : newChatLines()),
});

// Drive one mounted pair into the chat pane: open and resync, then react to each "session" event.
/** @type {ChatSession} */
const chatSession = {
  connKey: LOCAL,
  sessionId: null,
  creating: false,
  gen: 0,

  /** @param {string} connKey @param {string | null | undefined} id */
  open(connKey, id) {
    if (id == null) {
      id = connKey;
      connKey = LOCAL;
    }
    if (this.sessionId && (this.connKey !== connKey || this.sessionId !== id)) {
      client.sessionClose(this.connKey, this.sessionId);
    }
    this.connKey = connKey;
    this.sessionId = id;
    client.sessionOpen(this.connKey, id);
    client.sessionResync(this.connKey, id).catch(() => {});
    this.reload();
  },

  // Send composer text into the open session. It returns false with no session, so the composer
  // keeps the text; the message appears through the "session" fold, not optimistically.
  /** @param {string} text @returns {boolean} */
  send(text) {
    if (!this.sessionId) return this.startChat(text);
    client.sessionSendInput(this.connKey, this.sessionId, text).catch((e) => {
      restoreInput(text);
      notice.show("send failed · " + ((e && e.message) || "unknown"));
      root.invalidate();
    });
    return true;
  },

  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.connKey, this.sessionId, true).catch(() => {});
  },

  // A structural change (open, commit, resync): re-pull the outline.
  // A missing replica must not empty the pane; that would drop user fold overrides.
  reload() {
    if (!this.sessionId) return;
    const o = client.sessionOutline(this.connKey, this.sessionId);
    if (!o || !Array.isArray(o.messages)) return;
    chat.transcript.setOutline(o.messages, o.active || null);
    root.invalidate();
  },

  // A draft delta: re-wrap only the streaming message `id`.
  /** @param {number} id */
  active(id) {
    chat.transcript.setActive(id);
    root.invalidate();
  },

  // Create the session, mount it, then send the first message. The daemon makes a session only
  // once a chat has something to say.
  /** @param {string} text @returns {boolean} */
  startChat(text) {
    if (this.creating) return false;
    if (this.connKey !== LOCAL) {
      notice.show("a new chat needs the local daemon");
      return false;
    }
    if (!term.cwd) {
      notice.show("no workspace directory");
      return false;
    }
    const connKey = this.connKey;
    const d = defaultModel();
    const params = /** @type {CreateSessionDraft} */ ({ workspace_path: term.cwd });
    if (d.model) params.model = d.model;
    if (d.reasoning) params.reasoning = d.reasoning;
    const token = ++this.gen;
    this.creating = true;
    client
      .sessionCreate(connKey, params)
      .then((r) => {
        if (token !== this.gen) return null;
        this.open(connKey, r.session.id);
        return client.sessionSendInput(connKey, r.session.id, text);
      })
      .catch((e) => {
        restoreInput(text);
        notice.show("new chat failed · " + ((e && e.message) || "unknown"));
        root.invalidate();
      })
      .then(() => {
        if (token === this.gen) this.creating = false;
      });
    return true;
  },

  // Leave the open session and show an empty pane. The daemon makes the session on the first
  // message, so nothing is created until the user sends one.
  newChat() {
    this.gen++;
    this.creating = false;
    if (this.sessionId) client.sessionClose(this.connKey, this.sessionId);
    this.sessionId = null;
    this.connKey = LOCAL;
    chat.transcript.setOutline([], null);
    sidebar.active = null;
    root.focusView(chat);
    root.invalidate();
  },

  // The daemon lost the session. Clear the pane back to the placeholder.
  close() {
    this.sessionId = null;
    chat.transcript.setOutline([], null);
    root.invalidate();
  },
};

events.on("session.changed", /** @param {NativeSessionEvent} ev */ (ev => {
  if (!ev || ev.connKey !== chatSession.connKey || ev.sessionId !== chatSession.sessionId) return;
  if (ev.kind === "gone") chatSession.close();
  else if (ev.kind === "active") chatSession.active(/** @type {number} */ (ev.id));
  else chatSession.reload();
}));

events.on("conn.changed", /** @param {NativeConnEvent} ev */ (ev => {
  if (!ev || !ev.key) return;
  if (ev.kind !== "ready") return;
  loadCatalog(ev.key);
  if (ev.key === LOCAL) events.emit("daemon.ready");
  if (chatSession.connKey === ev.key && chatSession.sessionId && client.sessionRev(ev.key, chatSession.sessionId) < 0) {
    chatSession.open(ev.key, chatSession.sessionId);
  }
  root.invalidate();
}));

// Enter previews the session and stays on the list. Click, `l`, and → move into the chat.
// The roster belongs to the connection, so the shell names a device for the sidebar.
/** @param {string} connKey @returns {string} */
function deviceName(connKey) {
  if (connKey === LOCAL) return "local";
  if (connKey.indexOf("remote:") !== 0) return "";
  const id = connKey.slice("remote:".length);
  const d = connection.roster.find((x) => x.device_id === id);
  return (d && d.name) || id.slice(0, 7);
}

const sidebar = new SessionList({
  statusLabel: connectionLabel,
  onOpen: (connKey, id, src) => {
    chatSession.open(connKey, id);
    if (src !== "key") root.focusView(chat);
  },
});

const workspace = Node.branch("row", new Node(sidebar), new Node(chat), SIDEBAR_RATIO);

// --- explorer -----------------------------------------------------------------------------
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

        const content = /** @type {import("yuke:ui").Picker<ExplorerRow>} */ (/** @type {unknown} */ (picker.content));
        content.query = "";
        content.setSource(rows);
        root.invalidate();
      },
      () => {
        const content = /** @type {import("yuke:ui").Picker<ExplorerRow>} */ (/** @type {unknown} */ (picker.content));
        content.query = "";
        content.setSource([{ key: "\x00err", notice: true, text: "cannot browse — daemon offline?" }]);
        root.invalidate();
      },
    );
  }

  go(state.path || null);
  return picker;
}

// --- command palette ----------------------------------------------------------------------
// A picker over the command registry: it lists the commands the current context allows and runs
// the chosen one.
// The first stroke bound to `name`, for the palette's hint column.


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
      sidebar.active = { connKey: r.connKey, sessionId: r.id };
      sidebar.list.selectedKey = rowKey(r);
      chatSession.open(r.connKey, r.id);
    },
  });
}

// Pick any message in the transcript and copy its source text.
function openMessagePicker() {
  const items = chat.transcript.messages().map((m, i) => ({ m, i, text: chat.transcript.textFor(m) }));
  if (items.length === 0) {
    notice.show("nothing to copy");
    return null;
  }
  return ui.pick({
    title: "copy a message",
    footer: "type to filter · ↵ copy · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.5,
    items: items.reverse(),
    key: r => r.m.id,
    filterText: r => r.text,
    format: r => ({ text: firstLine(r.text) || "(empty)", right: r.m.type }),
    onAccept: r => copy(r.text, r.m.type + " message"),
  });
}

// Pick any fenced code block in the transcript and copy its body.
function openModelPicker() {
  const connKey = chatSession.connKey;
  const current = chatEntry();
  const currentId = current && current.session ? current.session.model : null;
  const show = () => {
    const models = catalogOf(connKey).models.slice().sort((a, b) => a.provider.localeCompare(b.provider) || a.name.localeCompare(b.name));
    if (models.length === 0) {
      notice.show("no model in the catalog");
      return null;
    }
    // The daemon owns the selector format. The picker keys on it and never builds one.
    /** @param {Wire.ModelInfo} m @returns {string} */
    const qualified = (m) => m.selector;
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: 0.6,
      height: 0.6,
      items: models,
      key: qualified,
      filterText: m => m.provider + " " + m.name + " " + m.id,
      format: m => ({ text: m.name, right: m.provider }),
      onAccept: m => pickReasoning(connKey, m),
    });
    p.content.selectKey(currentId);
    return p;
  };
  loadCatalog(connKey).then(show);
  return null;
}

// A model with one level needs no second step, so the pick ends there.
/** @param {string} connKey @param {Wire.ModelInfo} model @returns {void} */
function pickReasoning(connKey, model) {
  const levels = model.reasoning_levels;
  if (levels.length < 2) {
    chooseModel(model, model.default_reasoning || levels[0] || "");
    return;
  }
  ui.pick({
    title: model.name + " · effort",
    footer: "↵ select · esc close",
    border: "rounded",
    width: 0.4,
    height: 0.4,
    items: levels.map((id) => ({ id })),
    key: l => l.id,
    filterText: l => l.id,
    format: l => ({ text: l.id }),
    onAccept: l => chooseModel(model, l.id),
  }).content.selectKey(model.default_reasoning || levels[0]);
}

function openCodePicker() {
  const blocks = chat.transcript.codeBlocks();
  if (blocks.length === 0) {
    notice.show("no code block");
    return null;
  }
  return ui.pick({
    title: "copy a code block",
    footer: "type to filter · ↵ copy · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.5,
    items: blocks.map((b, i) => ({ ...b, i })),
    key: b => b.i,
    filterText: b => b.lang + " " + b.text,
    format: b => ({ text: firstLine(b.text) || "(empty)", right: b.lang }),
    onAccept: b => copy(b.text, b.lang ? b.lang + " block" : "code block"),
  });
}

// The first line of `s`, for a one-row picker label.
/** @param {string} s @returns {string} */
function firstLine(s) {
  const i = s.indexOf("\n");
  return (i < 0 ? s : s.slice(0, i)).trim();
}

// --- command line -------------------------------------------------------------------------

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
    // The interrupt command is available only with a session open.
    ctx.command(() => chatSession.sessionId != null, {
      "session:interrupt": () => chatSession.interrupt(),
    });

    ctx.command(null, {
      "app:quit": () => quit(),
      "ui:sessions": () => openSessionFinder(),
      "app:connect": () => connection.attempt(),
      "app:explorer": () => openExplorer(),
      "focus:left": () => root.focusDir("h"),
      "focus:down": () => root.focusDir("j"),
      "focus:up": () => root.focusDir("k"),
      "focus:right": () => root.focusDir("l"),
      "focus:next": () => root.focusCycle(1),
      "focus:prev": () => root.focusCycle(-1),
      "window:split-right": () => root.split("row", new MainPane()),
      "window:split-down": () => root.split("col", new MainPane()),
      "window:close": () => root.close(),
      "copy:reply": () => copy(chat.transcript.textFor(chat.transcript.last("assistant")), "reply"),
      "copy:selection": () => copy(chat.transcript.selectedText(), "selection"),
      "copy:source": () => copy(chat.transcript.selectedSource(), "source"),
      "copy:message": () => openMessagePicker(),
      "copy:code": () => openCodePicker(),
      "model:pick": () => openModelPicker(),
      "chat:new": () => chatSession.newChat(),
      "chat:focus-toggle": () => {
        chat.focusRegion(chat.focus === "transcript" ? "composer" : "transcript");
        root.invalidate();
      },
      "composer-vim:toggle": () => (plugins.get("composer-vim") ? plugins.dispose("composer-vim") : plugins.use(composerVim)),
      "transcript-vim:toggle": () => (plugins.get("transcript-vim") ? plugins.dispose("transcript-vim") : plugins.use(transcriptVim)),
    });

    // Global commands live on ctrl strokes, so they never collide with typing. Window nav is a
    // ctrl+k prefix (it works during text entry), which leaves ctrl+w for the composer word-erase.
    // Tab moves between the two regions of the chat pane, with or without a vim layer.
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
plugins.use(sidebarPlugin, { deviceName, onCatalogChanged: /** @param {string} connKey @returns {void} */ (connKey) => { catalogOf(connKey).rev = null; } });

plugins.use({
  name: "connection",
  /** @param {import("yuke:ext").Context} ctx */
  apply(ctx) {
    ctx.service(connection);
  },
});

root.setRoot(workspace);
root.focusView(chat);

export { workspace, sidebar, chat, SessionList, MainPane, DeviceFeed, openExplorer, openSessionFinder, connection };
