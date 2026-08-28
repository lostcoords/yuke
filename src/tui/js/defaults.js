// yuke:defaults — the bundled UI: a sidebar | chat split shell with a local connect, a command
// palette, a ":" line, and a stub explorer. A user's index.js layers on top.
import { term } from "yuke:term";
import { command, keymap, style, clip, fill, text, strokeOf, TextInput, caretCol, Node, root, quit, config, events } from "yuke:core";
import { plugins } from "yuke:ext";
import { ui, List, Transcript, Composer } from "yuke:ui";
import * as client from "yuke:client";
import { vim } from "yuke:vim";

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

// The sidebar: merged DeviceFeed rows, newest first, two lines each. Enter opens the pair.
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
    if (strokeOf(ev) === "enter") {
      const row = this.list.selected();
      if (row) {
        this.active = { connKey: row.connKey, sessionId: row.id };
        if (this.onOpen) this.onOpen(row.connKey, row.id);
      }
      return true;
    }
    return false;
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
    if (sw <= 0 || h <= 0) return;

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
    if (h <= 0 || w <= 0) return;

    const conns = client.connections();
    const ready = conns.some((c) => c.state === "ready");
    const busy = conns.some((c) => c.state === "connecting" || c.state === "closing");
    if (!ready) {
      text(x, top, clip(busy ? "…" : "not connected", w), "YukeEmpty");
      return;
    }
    if (this.list.items.length === 0) {
      const loading = [...feeds.values()].some((f) => !f.loaded);
      text(x, top, clip(loading ? "loading…" : "no sessions", w), "YukeEmpty");
      return;
    }

    this.list.drawCursor = focused;
    this.list.draw({ x, y: top, w, h });
  }
}

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

// The chat pane: a transcript above a composer in one leaf. setOutline feeds the transcript (text
// via textOf); the composer calls onSubmit(text); an unconsumed key scrolls the transcript.
class ChatView {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.transcript = new Transcript({ textOf: opts.textOf });
    this.composer = new Composer({ placeholder: "Message…", onSubmit: opts.onSubmit });
  }

  get name() {
    return "chat";
  }

  setOutline(messages, active) {
    this.transcript.setOutline(messages, active);
  }

  setActive(id) {
    this.transcript.setActive(id);
  }

  onKey(ev) {
    return this.composer.onKey(ev) || this.transcript.onKey(ev);
  }

  draw(focused) {
    const { x, y, w, h } = this.rect;
    this.composer.rect = { x, y: y + Math.max(0, h - 1), w, h: h > 0 ? 1 : 0 };
    if (w <= 0 || h <= 0) return;

    if (h > 2) this.transcript.draw({ x, y, w, h: h - 2 });
    if (h >= 2) text(x, y + h - 2, "─".repeat(w), "YukeRule");
    this.composer.draw(focused);
  }

  cursor() {
    return this.composer.cursor();
  }
}

// --- default layout -----------------------------------------------------------------------
const chat = new ChatView({
  textOf: (id) => (chatSession.sessionId ? client.sessionText(chatSession.connKey, chatSession.sessionId, id) : ""),
  onSubmit: (text) => chatSession.send(text),
});

// Drive one mounted pair into the chat pane: open and resync, then react to each "session" event.
const chatSession = {
  connKey: LOCAL,
  sessionId: null,

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
    if (!this.sessionId) return false;
    client.sessionSendInput(this.connKey, this.sessionId, text).catch(() => {
      if (chat.composer.text === "") chat.composer.text = text;
      root.invalidate();
    });
    return true;
  },

  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.connKey, this.sessionId, true).catch(() => {});
  },

  // A structural change (open, commit, resync): re-pull the outline.
  reload() {
    const o = this.sessionId ? client.sessionOutline(this.connKey, this.sessionId) : null;
    chat.setOutline(o ? o.messages : [], o ? o.active : null);
    root.invalidate();
  },

  // A draft delta: re-wrap only the streaming message `id`.
  active(id) {
    chat.setActive(id);
    root.invalidate();
  },
};

events.on("session", (ev) => {
  if (!ev || ev.connKey !== chatSession.connKey || ev.sessionId !== chatSession.sessionId) return;
  if (ev.kind === "active") chatSession.active(ev.id);
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

const sidebar = new SessionList({ onOpen: (connKey, id) => chatSession.open(connKey, id) });

const workspace = Node.branch("row", new Node(sidebar), new Node(chat), SIDEBAR_RATIO);

// --- explorer -----------------------------------------------------------------------------
// A floating directory navigator over the workspace.browse fixture, fuzzy-filtered as you type.
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
      "vim:toggle": () => (plugins.get("vim") ? plugins.dispose("vim") : plugins.use(vim)),
    });

    // Global commands live on ctrl strokes, so they never collide with typing. Window nav is a
    // ctrl+k prefix (it works during text entry), which leaves ctrl+w for the composer word-erase.
    ctx.keymap({
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

// Load vim at start when the user opted in with `config.vim`. Read at "start", so an index.js that
// sets it (index.js loads after this module) is honored; :vim / vim:toggle flips it at runtime.
events.on("start", () => {
  if (config.vim && !plugins.get("vim")) plugins.use(vim);
});

export { workspace, sidebar, chat, ChatView, SessionList, MainPane, DeviceFeed, openExplorer, openPalette, openSessionFinder, openCommandLine, connection };
