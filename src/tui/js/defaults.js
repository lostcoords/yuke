// yuke:defaults — the bundled UI: a sidebar | chat split shell with a local connect, a command
// palette, a ":" line, and a stub explorer. A user's index.js layers on top.
import { term } from "yuke:term";
import { command, keymap, style, status, copy, clip, fill, text, strokeOf, TextInput, caretCol, Node, root, quit, config, events } from "yuke:core";
import { plugins } from "yuke:ext";
import { ui, ChatView, List } from "yuke:ui";
import * as client from "yuke:client";
import { composerVim } from "yuke:composer-vim";
import { transcriptVim } from "yuke:transcript-vim";

// The ":" command line: the prompt links to Normal; an unmatched word shows in red. Seed each group
// alone, so a theme that set one first keeps it.
const CMDLINE_GROUPS = { YukeCmdline: { link: "Normal" }, YukeCmdlineErr: { fg: "danger", bold: true } };
let seededCmdline = false;
for (const name in CMDLINE_GROUPS) {
  if (!(name in style.groups)) {
    style.groups[name] = CMDLINE_GROUPS[name];
    seededCmdline = true;
  }
}
if (seededCmdline) style.invalidate();

// The sidebar's share of the width in the default row split.
const SIDEBAR_RATIO = 0.28;

// The local conn key. A remote is `remote:<device_id>`. An empty `devices()` means no relay.
const LOCAL = "local";

const IDLE_ACTIVITY = {
  state: { type: "idle" },
  queued: 0,
  context_usage: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 },
  pending_compaction: null,
};

// --- device feed --------------------------------------------------------------------------
// A per-connection inbox. It folds ungated index events; it is not a replica.
class DeviceFeed {
  constructor(connKey) {
    this.connKey = connKey;
    this.name = connKey === LOCAL ? "local" : "";
    this.items = new Map();
    this.workspaces = new Map();
    this.pending = [];
    this.loaded = false;
  }

  learnWorkspaces(list) {
    if (!list) return;
    for (const ws of list) if (ws && ws.id) this.workspaces.set(ws.id, ws);
  }

  seed(listResult) {
    this.items.clear();
    const items = listResult && listResult.items ? listResult.items : [];
    for (const it of items) if (it && it.session) this.items.set(it.session.id, it);
    this.loaded = true;
    const pending = this.pending;
    this.pending = [];
    for (const ev of pending) this._apply(ev);
  }

  fold(ev) {
    if (!this.loaded) {
      this.pending.push(ev);
      return;
    }
    this._apply(ev);
  }

  _apply(ev) {
    const p = ev && ev.params ? ev.params : {};
    switch (ev && ev.method) {
      case "session.summary_changed":
        this._upsert(p.session);
        break;
      case "catalog.changed":
        catalogOf(this.connKey).rev = null;
        break;
      case "session.activity_changed": {
        const existing = this.items.get(p.session_id);
        if (existing) this.items.set(p.session_id, { session: existing.session, activity: p.activity });
        break;
      }
      case "session.removed":
        this.items.delete(p.session_id);
        break;
      case "workspace.created":
        if (p.workspace && p.workspace.id) this.workspaces.set(p.workspace.id, p.workspace);
        break;
      case "workspace.removed":
        this.workspaces.delete(p.workspace_id);
        break;
    }
  }

  _upsert(session) {
    if (!session || !session.id) return;
    const existing = this.items.get(session.id);
    this.items.set(session.id, { session, activity: existing ? existing.activity : IDLE_ACTIVITY });
  }

  clear() {
    this.items.clear();
    this.workspaces.clear();
    this.pending = [];
    this.loaded = false;
  }

  rows() {
    const out = [];
    for (const it of this.items.values()) {
      out.push({
        connKey: this.connKey,
        id: it.session.id,
        title: sessionTitle(it.session),
        activity: it.activity,
        session: it.session,
        workspace: this.workspaces.get(it.session.workspace_id) || null,
        deviceName: this.name,
      });
    }
    return out;
  }
}

const feeds = new Map();

function feedOf(connKey) {
  let f = feeds.get(connKey);
  if (!f) {
    f = new DeviceFeed(connKey);
    feeds.set(connKey, f);
  }
  return f;
}

function mergedRows() {
  const all = [];
  for (const f of feeds.values()) {
    for (const row of f.rows()) all.push(row);
  }
  all.sort((a, b) => (b.session.updated_at_ms || 0) - (a.session.updated_at_ms || 0));
  return all;
}

function rowKey(row) {
  return row.connKey + "\0" + row.id;
}

function rowLabel(row) {
  if (feeds.size <= 1 && row.connKey === LOCAL) return row.title;
  const name = row.deviceName || (row.connKey === LOCAL ? "local" : row.connKey.slice("remote:".length, "remote:".length + 7));
  return name + " · " + row.title;
}

function sessionTitle(s) {
  const t = (s && s.title ? s.title : "").trim();
  return t !== "" ? t : "untitled";
}

// A one-cell activity mark: "!" needs attention, "●" working, "" idle.
function activityMark(activity) {
  const type = activity && activity.state ? activity.state.type : "idle";
  if (type === "waiting_permission") return "!";
  return type === "idle" ? "" : "●";
}

// The session's relative age, for the sidebar's right column.
function relTime(ms) {
  if (!ms) return "";
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (s < 60) return "now";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// The sidebar row's second line: workspace and model.
function metaLabel(row) {
  const ws = row.workspace && row.workspace.title ? row.workspace.title : "";
  const model = row.session && row.session.model ? row.session.model : "";
  return [ws, model].filter(Boolean).join(" · ") || "—";
}

// --- panes --------------------------------------------------------------------------------
// A pane is a node-leaf view: it owns its rect, draws with draw(focused), and returns whether
// onKey(ev) consumed the key. The node tree assigns rects and routes focus.

// The sidebar: merged DeviceFeed rows, newest first, two lines each. Enter previews the pair.
class SessionList {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.list = new List({
      key: rowKey,
      itemHeight: 2,
      format: (row) => this._format(row),
      group: "YukeSession",
      selGroup: "YukeSessionSel",
    });
    this.onOpen = opts.onOpen || null;
    this.active = null;
  }

  get name() {
    return "sessions";
  }

  get activeId() {
    return this.active ? this.active.sessionId : null;
  }

  update() {
    this.list.setItems(mergedRows());
  }

  current() {
    return this.list.selected();
  }

  onKey(ev) {
    if (this.list.onKey(ev)) return true;
    const s = strokeOf(ev);
    if (s === "enter") {
      this.open(this.list.selected(), "key");
      return true;
    }
    // `l`/`right` open and enter the chat, the way a vim window takes `l`.
    if (s === "l" || s === "right") {
      this.open(this.list.selected(), "go");
      return true;
    }
    return false;
  }

  // A left click selects a row and opens its pair, the same as Enter. A wheel step only moves.
  onMouse(ev) {
    if (!this.list.onMouse(ev)) return false;
    if (ev.button === "left") this.open(this.list.selected(), "mouse");
    return true;
  }

  // `src` is "key" (preview, stay), "go" (jump in), or "mouse" (jump in).
  open(row, src) {
    if (!row) return;
    this.active = { connKey: row.connKey, sessionId: row.id };
    if (this.onOpen) this.onOpen(row.connKey, row.id, src);
  }

  // A two-line row: an activity mark and title over a faint workspace and model. The active pair
  // prefixes its title with "▸", so the mark and the active cue stay independent.
  _format(row) {
    const active = this.active && this.active.connKey === row.connKey && this.active.sessionId === row.id;
    const mark = activityMark(row.activity);
    return {
      lines: [
        {
          marker: mark || null,
          markerGroup: "YukeSessionMeta",
          markerSelGroup: "YukeSessionMetaSel",
          indent: 2,
          text: (active ? "▸ " : "") + rowLabel(row),
          right: relTime(row.session.updated_at_ms),
          group: "YukeSession",
          selGroup: "YukeSessionSel",
          rightGroup: "YukeSessionMeta",
          rightSelGroup: "YukeSessionMetaSel",
        },
        { indent: 2, text: metaLabel(row), group: "YukeSessionMeta", selGroup: "YukeSessionMetaSel" },
      ],
    };
  }

  draw(focused) {
    const { x, y, w: sw, h } = this.rect;
    if (sw <= 0 || h <= 0) {
      this.list.clearRect();
      return;
    }

    const pad = sw >= 4 ? 1 : 0;
    const iw = Math.max(0, sw - pad * 2);
    let row = y;

    if (row < y + h) {
      text(x + pad, row, clip("yuke", iw), "YukeBrand");
      row++;
    }
    if (row < y + h) {
      text(x + pad, row, clip(connectionLabel(), iw), "YukeStatus");
      row++;
    }
    if (row < y + h) {
      text(x + pad, row, clip("─".repeat(iw), iw), "YukeRule");
      row++;
    }

    const footerY = y + h - 1;
    this._drawList(x + pad, row, iw, Math.max(0, footerY - row), focused);

    if (footerY >= y) {
      text(x + pad, footerY, clip("j/k move · ↵ open · ^k h/l pane", iw), "YukeFooter");
    }
  }

  // The rows, or an empty/status line. The List paints the two-line rows; the cursor shows only
  // when the pane is focused.
  _drawList(x, top, w, h, focused) {
    if (h <= 0 || w <= 0) {
      this.list.clearRect();
      return;
    }

    const conns = client.connections();
    const ready = conns.some((c) => c.state === "ready");
    const busy = conns.some((c) => c.state === "connecting" || c.state === "closing");
    if (!ready) {
      text(x, top, clip(busy ? "…" : "not connected", w), "YukeEmpty");
      this.list.clearRect();
      return;
    }
    if (this.list.items.length === 0) {
      const loading = [...feeds.values()].some((f) => !f.loaded);
      text(x, top, clip(loading ? "loading…" : "no sessions", w), "YukeEmpty");
      this.list.clearRect();
      return;
    }

    this.list.drawCursor = focused;
    this.list.draw({ x, y: top, w, h });
  }
}

// A transient notice replaces the chat rule row until the next key press.
const notice = {
  text: "",
  show(s) {
    this.text = s;
    root.invalidate();
  },
  clear() {
    if (this.text === "") return;
    this.text = "";
    root.invalidate();
  },
};

// Clear the notice before each key press dispatches. A key release must not clear a fresh notice.
events.on("key", (ev) => {
  if (ev.event === "press") notice.clear();
});

// Report every copy, wherever it came from. OSC 52 has no acknowledgement, so a byte count means
// the sequence left this process, not that the terminal accepted it.
events.on("copy", (e) => {
  if (!e) return;
  if (e.text === "") notice.show("nothing to copy");
  else if (e.bytes < 0) notice.show("too large to copy · over " + term.clipboardMax + " bytes");
  else notice.show("copied " + e.what + " · " + e.bytes + " bytes");
});

// One catalog per connection. `catalog.list` answers "unchanged" while the revision holds, so a
// reopened picker costs no round trip.
const catalogs = new Map();

function catalogOf(connKey) {
  let c = catalogs.get(connKey);
  if (!c) {
    c = { rev: null, models: [], providers: [], loading: false };
    catalogs.set(connKey, c);
  }
  return c;
}

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
function contextWindowOf(connKey, modelId) {
  if (!modelId) return 0;
  const m = catalogOf(connKey).models.find((x) => x.provider + "/" + x.id === modelId);
  return m && m.context_window ? m.context_window : 0;
}

// The model a new chat starts with. `session.patch` is not implemented, so a choice cannot move an
// open session yet.
const chatDefaults = { model: null, reasoning: "" };

function chooseModel(model, reasoning) {
  chatDefaults.model = model.provider + "/" + model.id;
  chatDefaults.reasoning = reasoning;
  notice.show("model · " + model.name + (reasoning ? " · " + reasoning : ""));
  root.invalidate();
}

// Without a choice this run, the newest session names the model and reasoning, so a restart keeps working.
function defaultModel() {
  if (chatDefaults.model) return chatDefaults;
  for (const r of mergedRows()) {
    if (r.connKey === LOCAL && r.session && r.session.model)
      return { model: r.session.model, reasoning: r.session.reasoning };
  }
  return chatDefaults;
}

function restoreInput(text) {
  const now = chat.composer.text;
  chat.composer.text = now === "" ? text : text + "\n" + now;
}

// The chat's live entry, or null with no open session.
function chatEntry() {
  if (!chatSession.sessionId) return null;
  const feed = feeds.get(chatSession.connKey);
  return feed ? feed.items.get(chatSession.sessionId) : null;
}

// Round a token count to a short label. The catalog is not in the TUI, so this is not a percentage.
function tokenLabel(n) {
  if (n < 1000) return String(n);
  return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
}

status.add({ side: "left", order: 0, render: () => notice.text });
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
    const u = e && e.activity ? e.activity.context_usage : null;
    if (!u || !u.input) return "";
    const win = contextWindowOf(chatSession.connKey, e.session && e.session.model);
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

  onKey(_ev) {
    return false;
  }

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
  textOf: (id) => (chatSession.sessionId ? client.sessionText(chatSession.connKey, chatSession.sessionId, id) : ""),
  partsOf: (id) => (chatSession.sessionId ? client.sessionParts(chatSession.connKey, chatSession.sessionId, id) : []),
  onSubmit: (text) => chatSession.send(text),
  onSelect: (text) => {
    if (config.mouse.copyOnSelect) copy(text, "selection");
  },
  empty: () => (chatSession.sessionId ? null : newChatLines()),
});

// Drive one mounted pair into the chat pane: open and resync, then react to each "session" event.
const chatSession = {
  connKey: LOCAL,
  sessionId: null,
  creating: false,
  gen: 0,

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
  active(id) {
    chat.transcript.setActive(id);
    root.invalidate();
  },

  // Create the session, mount it, then send the first message. The daemon makes a session only
  // once a chat has something to say.
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
    const params = { workspace_path: term.cwd };
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

events.on("session", (ev) => {
  if (!ev || ev.connKey !== chatSession.connKey || ev.sessionId !== chatSession.sessionId) return;
  if (ev.kind === "gone") chatSession.close();
  else if (ev.kind === "active") chatSession.active(ev.id);
  else chatSession.reload();
});

events.on("index", (ev) => {
  if (!ev || !ev.connKey) return;
  const f = feeds.get(ev.connKey);
  if (!f) return;
  f.fold(ev);
  root.invalidate();
});

events.on("conn", (ev) => {
  if (!ev || !ev.key) return;
  if (ev.kind === "ready") {
    loadCatalog(ev.key);
    const f = feedOf(ev.key);
    const info = client.connections().find((c) => c.key === ev.key);
    f.name = (info && info.name) || (ev.key === LOCAL ? "local" : f.name);
    if (!f.name && ev.key.indexOf("remote:") === 0) {
      const id = ev.key.slice("remote:".length);
      const d = connection.roster.find((x) => x.device_id === id);
      f.name = (d && d.name) || id.slice(0, 7);
    }
    f.learnWorkspaces(ev.workspaces);
    client.sessionList(ev.key).then(
      (res) => {
        f.seed(res);
        root.invalidate();
      },
      () => root.invalidate(),
    );
    if (ev.key === LOCAL) events.emit("daemon:ready");
    if (chatSession.connKey === ev.key && chatSession.sessionId && client.sessionRev(ev.key, chatSession.sessionId) < 0) {
      chatSession.open(ev.key, chatSession.sessionId);
    }
    root.invalidate();
    return;
  }
  if (ev.kind === "close") {
    const f = feeds.get(ev.key);
    if (f) f.clear();
    feeds.delete(ev.key);
    root.invalidate();
  }
});

// Enter previews the session and stays on the list. Click, `l`, and → move into the chat.
const sidebar = new SessionList({
  onOpen: (connKey, id, src) => {
    chatSession.open(connKey, id);
    if (src !== "key") root.focusView(chat);
  },
});

const workspace = Node.branch("row", new Node(sidebar), new Node(chat), SIDEBAR_RATIO);

// --- explorer -----------------------------------------------------------------------------
// A floating directory navigator over the workspace.browse RPC, fuzzy-filtered as you type.
// Enter/→ descends; ← goes to the parent; Esc closes.
function openExplorer(startPath) {
  const state = { path: startPath || "", parent: null };

  const picker = ui.pick({
    title: () => state.path || "…",
    footer: "type to filter · ↵/→ enter · ← up · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.6,
    key: (e) => e.key,
    filterText: (e) => e.name || "",
    isSelectable: (e) => !e.notice,
    format: (e) => {
      if (e.notice) return { text: e.text, group: "UIDim" };
      if (e.up) return { text: "..", group: "UIDim" };
      return { text: e.name + "/", right: e.is_git_repo ? "git" : "" };
    },
    onAccept: (e) => {
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

  function go(path) {
    client.workspaceBrowse(LOCAL, path != null ? { path } : {}).then(
      (res) => {
        state.path = res.path;
        state.parent = res.parent;

        const rows = [];
        if (res.parent != null) rows.push({ key: "..", up: true, dest: res.parent });
        for (const e of res.entries) {
          rows.push({ key: e.path, name: e.name, path: e.path, is_git_repo: e.is_git_repo });
        }
        if (res.next_cursor != null) rows.push({ key: "\x00more", notice: true, text: "… more entries not shown" });

        picker.content.query = "";
        picker.content.setSource(rows);
        root.invalidate();
      },
      () => {
        picker.content.query = "";
        picker.content.setSource([{ key: "\x00err", notice: true, text: "cannot browse — daemon offline?" }]);
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
function commandAvailable(cmd) {
  if (!cmd || !cmd.predicate) return true;
  try {
    const r = cmd.predicate();
    return Array.isArray(r) ? !!r[0] : !!r;
  } catch (_e) {
    return true;
  }
}

// The first stroke bound to `name`, for the palette's hint column.
function keyHint(name) {
  for (const stroke in keymap.map) {
    const list = keymap.map[stroke];
    if (list && list.indexOf(name) >= 0) return stroke;
  }
  return "";
}

function openPalette() {
  const cmds = Object.keys(command.map)
    .sort()
    .filter((name) => commandAvailable(command.map[name]))
    .map((name) => ({ name: name, hint: keyHint(name) }));

  return ui.pick({
    title: "commands",
    footer: "type to filter · ↵ run · esc close",
    border: "rounded",
    width: 0.5,
    height: 0.5,
    items: cmds,
    key: (c) => c.name,
    filterText: (c) => c.name,
    format: (c) => ({ text: c.name, right: c.hint }),
    onAccept: (c) => command.perform(c.name),
  });
}

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
    filterText: (r) => rowLabel(r),
    format: (r) => ({ text: rowLabel(r), right: activityMark(r.activity) }),
    onAccept: (r) => {
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
    key: (r) => r.m.id,
    filterText: (r) => r.text,
    format: (r) => ({ text: firstLine(r.text) || "(empty)", right: r.m.type }),
    onAccept: (r) => copy(r.text, r.m.type + " message"),
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
    const qualified = (m) => m.provider + "/" + m.id;
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: 0.6,
      height: 0.6,
      items: models,
      key: qualified,
      filterText: (m) => m.provider + " " + m.name + " " + m.id,
      format: (m) => ({ text: m.name, right: m.provider }),
      onAccept: (m) => pickReasoning(connKey, m),
    });
    p.content.selectKey(currentId);
    return p;
  };
  loadCatalog(connKey).then(show);
  return null;
}

// A model with one level needs no second step, so the pick ends there.
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
    key: (l) => l.id,
    filterText: (l) => l.id,
    format: (l) => ({ text: l.id }),
    onAccept: (l) => chooseModel(model, l.id),
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
    key: (b) => b.i,
    filterText: (b) => b.lang + " " + b.text,
    format: (b) => ({ text: firstLine(b.text) || "(empty)", right: b.lang }),
    onAccept: (b) => copy(b.text, b.lang ? b.lang + " block" : "code block"),
  });
}

// The first line of `s`, for a one-row picker label.
function firstLine(s) {
  const i = s.indexOf("\n");
  return (i < 0 ? s : s.slice(0, i)).trim();
}

// --- command line -------------------------------------------------------------------------
// A vim-style ":" line: it matches a command's short name exactly or by unique prefix, gated to
// the commands the current context allows.
function commandShortNames() {
  const names = Object.create(null);
  for (const full in command.map) {
    if (!commandAvailable(command.map[full])) continue;
    const short = full.slice(full.lastIndexOf(":") + 1);
    if (!names[short]) names[short] = full;
  }
  return names;
}

function resolveCommand(word) {
  const names = commandShortNames();
  if (names[word]) return names[word];
  let hit = null;
  for (const short in names) {
    if (short.indexOf(word) !== 0) continue;
    if (hit) return null; // an ambiguous prefix
    hit = names[short];
  }
  return hit;
}

// A single bottom row that edits a command word and runs it on Enter. It is modal while open; Esc,
// or Backspace past the prompt, cancels.
class CommandLine {
  constructor() {
    this.input = new TextInput({ onChange: () => (this.error = "") });
    this.error = "";
  }

  get name() {
    return "command-line";
  }

  draw() {
    const w = term.width;
    const h = term.height;
    if (h <= 0 || w <= 0) return;
    const y = h - 1;
    const err = this.error !== "";
    fill(0, y, w, 1, "Normal");
    text(0, y, clip(err ? this.error : ":" + this.input.text, w), err ? "YukeCmdlineErr" : "YukeCmdline");
  }

  cursor() {
    if (this.error) return null;
    return { x: caretCol(term.width, ":", this.input.beforeCaret()), y: term.height - 1, visible: true };
  }

  submit() {
    const word = this.input.text.trim();
    if (word === "") {
      root.popOverlay(this);
      return;
    }
    const name = resolveCommand(word);
    if (!name) {
      this.error = "not a command: " + word;
      return;
    }
    root.popOverlay(this);
    command.perform(name);
  }

  onKey(ev) {
    const s = strokeOf(ev);
    if (s === "esc") {
      root.popOverlay(this);
      return true;
    }
    if (s === "enter") {
      this.submit();
      return true;
    }
    // Backspace past the empty prompt closes the line; otherwise the edit goes to the buffer.
    if (s === "backspace" && this.input.text === "") {
      root.popOverlay(this);
      return true;
    }
    this.input.onKey(ev);
    return true; // modal: consume every key
  }
}

function openCommandLine() {
  return root.pushOverlay(new CommandLine());
}

// --- daemon connection --------------------------------------------------------------------
const READY_POLL_MS = 1000;
const RETRY_POLL_MS = 500;

const NO_RETRY = {
  device_not_found: true,
  device_ambiguous: true,
  not_enrolled: true,
  identity_unreadable: true,
};

const connection = {
  nextRetryAt: 0,
  remoteRetryAt: Object.create(null),
  roster: [],
  rosterTried: false,

  onStart() {
    if (config.daemon.autoConnect === false) return;
    this.attempt();
  },

  attempt() {
    this.dialLocal();
    this.loadRoster();
    this.dialRemotes();
    root.invalidate();
  },

  dialLocal() {
    if (client.connectionState(LOCAL) !== "disconnected") return;
    this.nextRetryAt = 0;
    const d = config.daemon;
    const opts = { host: d.host, port: d.port };
    if (d.token) opts.token = d.token;
    try {
      client.connect(opts).then(
        () => root.invalidate(),
        () => {
          this.scheduleRetry();
          root.invalidate();
        },
      );
    } catch (_e) {
      this.scheduleRetry();
    }
  },

  loadRoster() {
    if (this.rosterTried) return;
    this.rosterTried = true;
    client.devices().then(
      (devs) => {
        this.roster = devs || [];
        this.dialRemotes();
        root.invalidate();
      },
      () => {
        this.roster = [];
      },
    );
  },

  dialRemotes() {
    if (config.daemon.autoConnect === false) return;
    const now = Date.now();
    for (const d of this.roster) {
      if (!d || d.is_self || !d.static_public_key) continue;
      const key = "remote:" + d.device_id;
      const st = client.connectionState(key);
      if (st !== "disconnected") continue;
      if (!d.online && !this.remoteRetryAt[key]) continue;
      if (this.remoteRetryAt[key] && now < this.remoteRetryAt[key]) continue;
      this.remoteRetryAt[key] = 0;
      try {
        client.connect({ remote: true, device: d.device_id }).then(
          () => root.invalidate(),
          (err) => {
            const code = err && err.code;
            if (NO_RETRY[code]) return;
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

  needsTick() {
    const st = client.connectionState(LOCAL);
    if (st === "ready") return { periodMs: READY_POLL_MS };
    if (st === "connecting" || st === "closing") return { periodMs: RETRY_POLL_MS };
    if (config.daemon.autoConnect !== false || this.nextRetryAt > 0) return { periodMs: RETRY_POLL_MS };
    return null;
  },

  tick() {
    if (config.daemon.autoConnect === false) return;
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
    return ready[0].key === LOCAL ? "local · connected" : (ready[0].name || ready[0].key) + " · connected";
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
  apply(ctx) {
    // The interrupt command is available only with a session open.
    ctx.command(() => chatSession.sessionId != null, {
      "session:interrupt": () => chatSession.interrupt(),
    });

    ctx.command(null, {
      "app:quit": () => quit(),
      "ui:palette": () => openPalette(),
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
      "ui:cmdline": () => openCommandLine(),
      "copy:reply": () => copy(chat.transcript.textFor(chat.transcript.last("assistant")), "reply"),
      "copy:selection": () => copy(chat.transcript.selectedText(), "selection"),
      "copy:source": () => copy(chat.transcript.selectedSource(), "source"),
      "copy:message": () => openMessagePicker(),
      "copy:code": () => openCodePicker(),
      "model:pick": () => openModelPicker(),
      "chat:new": () => chatSession.newChat(),
      "composer-vim:toggle": () => (plugins.get("composer-vim") ? plugins.dispose("composer-vim") : plugins.use(composerVim)),
      "transcript-vim:toggle": () => (plugins.get("transcript-vim") ? plugins.dispose("transcript-vim") : plugins.use(transcriptVim)),
    });

    // Global commands live on ctrl strokes, so they never collide with typing. Window nav is a
    // ctrl+k prefix (it works during text entry), which leaves ctrl+w for the composer word-erase.
    ctx.keymap({
      "ctrl+n": "chat:new",
      "ctrl+p": "ui:palette",
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

root.setRoot(workspace);
root.addService(connection);
root.focusView(chat);

export { workspace, sidebar, chat, SessionList, MainPane, DeviceFeed, openExplorer, openPalette, openSessionFinder, openCommandLine, connection };
