// yuke:defaults — bundled default UI: a sidebar | chat split shell with local daemon connect,
// command palette, ":" line, and a stub explorer. A user's yuke.js layers on top.
import { term } from "yuke:term";
import { command, keymap, style, clip, fill, text, strokeOf, TextInput, caretCol, Node, root, quit, config, events } from "yuke:core";
import { plugins } from "yuke:ext";
import { ui, List, Transcript, Composer } from "yuke:ui";
import * as client from "yuke:client";
import { vim } from "yuke:vim";

// The ":" command line: prompt links to Normal, an unmatched word shows in red.
Object.assign(style.groups, {
  YukeCmdline: { link: "Normal" },
  YukeCmdlineErr: { fg: 203, bold: true },
});
style.invalidate();

// The session sidebar's share of the width in the default row split.
const SIDEBAR_RATIO = 0.28;

// --- panes ----------------------------------------------------------------------------------
// A pane is a node-leaf view: it owns its rect, draws with draw(focused), and handles onKey(ev)
// (returning whether it consumed the key). The node tree assigns rects and routes focus.

function sessionTitle(s) {
  const t = (s.title || "").trim();
  return t !== "" ? t : "untitled";
}

// A one-cell activity mark: "!" needs attention, "●" working, "" idle.
function activityMark(activity) {
  const type = activity && activity.state ? activity.state.type : "idle";
  if (type === "waiting_permission") return "!";
  return type === "idle" ? "" : "●";
}

// The sidebar pane: the session.list rows, a cursor, and the active (opened) id. Loads on connect,
// clears on drop; Enter only marks a row active for now — opening it is a later package.
class SessionList {
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };

    // A List owns selection identity, scroll, and nav; we paint the rows ourselves (chrome + a
    // focus-only cursor), so it renders via ensureVisible, not draw().
    this.list = new List({ key: (r) => r.id });

    this.onOpen = opts.onOpen || null; // (id) => void, called when a row is opened
    this.activeId = null;
    this.loaded = false;
    this.loading = false;
    this.wasReady = false;
  }

  get name() {
    return "sessions";
  }

  // A leaf's view is updated before it draws each frame: load on the ready edge, clear on the drop
  // edge, and retry a failed load while still ready.
  update() {
    const ready = client.connectionState() === "ready";
    if (ready && !this.wasReady) {
      this.wasReady = true;
      this.refresh();
    } else if (!ready && this.wasReady) {
      this.wasReady = false;
      this.clear();
      root.invalidate();
    } else if (ready && !this.loaded && !this.loading) {
      this.refresh();
    }
  }

  refresh() {
    if (client.connectionState() !== "ready" || this.loading) return;

    this.loading = true;
    client.sessionList().then(
      (res) => {
        this.loading = false;
        this.loaded = true;
        this.list.setItems(res.items.map((it) => ({ id: it.session.id, title: sessionTitle(it.session), activity: it.activity })));
        root.invalidate();
      },
      () => {
        this.loading = false;
        root.invalidate();
      },
    );
  }

  clear() {
    this.list.setItems([]);
    this.activeId = null;
    this.loaded = false;
  }

  current() {
    return this.list.selected();
  }

  onKey(ev) {
    if (this.list.onKey(ev)) return true;

    if (strokeOf(ev) === "enter") {
      const row = this.list.selected();
      if (row) {
        this.activeId = row.id;
        if (this.onOpen) this.onOpen(row.id);
      }
      return true;
    }

    return false;
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
      text(x + pad, row, clip("local · " + connectionLabel(), iw), "YukeStatus");
      row++;
    }

    if (row < y + h) {
      text(x + pad, row, clip("─".repeat(iw), iw), "YukeRule");
      row++;
    }

    const footerY = y + h - 1;
    this._drawRows(x + pad, row, iw, Math.max(0, footerY - row), focused);

    if (footerY >= y) {
      text(x + pad, footerY, clip("j/k move · ↵ open · ^k h/l pane", iw), "YukeFooter");
    }
  }

  // The rows, or an empty/status line. Scrolls to keep the cursor in view.
  _drawRows(x, top, w, h, focused) {
    if (h <= 0 || w <= 0) return;

    const st = client.connectionState();
    if (st !== "ready") {
      text(x, top, clip(st === "connecting" || st === "closing" ? "…" : "not connected", w), "YukeEmpty");
      return;
    }

    const rows = this.list.items;
    if (rows.length === 0) {
      text(x, top, clip(this.loading ? "loading…" : "no sessions", w), "YukeEmpty");
      return;
    }

    this.list.ensureVisible(h);
    const first = this.list.scroll;

    for (let i = 0; i < h && first + i < rows.length; i++) {
      const idx = first + i;
      const rowY = top + i;
      const data = rows[idx];
      const isCursor = data.id === this.list.selectedKey && focused;
      const isActive = data.id === this.activeId;

      if (isCursor) fill(x, rowY, w, 1, "YukeSessionSel");

      const mark = activityMark(data.activity);
      const markW = mark ? 2 : 0;
      const prefix = isActive ? "▸ " : "  ";
      text(x, rowY, clip(prefix + data.title, Math.max(0, w - markW)), isCursor ? "YukeSessionSel" : "YukeSession");
      if (mark) {
        text(x + w - 1, rowY, mark, isCursor ? "YukeSessionMetaSel" : "YukeSessionMeta");
      }
    }
  }
}

// The main pane: a placeholder until a transcript + composer land in a later package.
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
    const st = client.connectionState();

    let msg;
    if (st !== "ready") {
      msg = st === "connecting" ? "connecting to local daemon…" : "daemon offline — :connect to retry";
    } else {
      msg = "select a session";
    }

    // Center the placeholder in the main pane body (leave a footer row for hints).
    const bodyH = Math.max(0, h - 1);
    const cy = y + Math.floor(Math.max(0, bodyH - 1) / 2);
    if (bodyH > 0) {
      text(x + pad, cy, clip(msg, iw), "YukeEmpty");
    }

    if (h > 0) {
      text(x + pad, y + h - 1, clip("^p palette · ^k h/l pane", iw), "YukeFooter");
    }
  }
}

// The chat pane: a transcript above a composer in one leaf. setOutline() feeds the transcript (text
// via textOf), the composer calls onSubmit(text); unconsumed keys scroll the transcript.
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
// The stock layout: the session sidebar beside the chat pane, a row split in the node tree. A
// user's yuke.js can rebuild `workspace` before it is installed.
const chat = new ChatView({ textOf: (id) => client.sessionText(id) });

// Drive the one open session into the chat pane: open + resync, then react to each "session" event.
// The transcript holds only the outline and pulls text on demand. Read-only — the composer can't submit.
const chatSession = {
  sessionId: null, // the last-opened session, re-opened on reconnect

  open(id) {
    this.sessionId = id;
    client.sessionOpen(id);
    client.sessionResync().catch(() => {}); // the "session" event refreshes; a reject retries on reopen
    this.reload();
  },

  // Structural change (open/commit/resync): re-pull the outline.
  reload() {
    const o = client.sessionOutline();
    chat.setOutline(o ? o.messages : [], o ? o.active : null);
    root.invalidate();
  },

  // Draft delta: re-wrap only the streaming message `id`.
  active(id) {
    chat.setActive(id);
    root.invalidate();
  },
};
events.on("session", (ev) => (ev && ev.kind === "active" ? chatSession.active(ev.id) : chatSession.reload()));

// A reconnect drops the native replica + subscription; re-open the last session so streaming resumes.
events.on("daemon:ready", () => {
  if (chatSession.sessionId && client.sessionRev() < 0) chatSession.open(chatSession.sessionId);
});

const sidebar = new SessionList({ onOpen: (id) => chatSession.open(id) });

const workspace = Node.branch("row", new Node(sidebar), new Node(chat), SIDEBAR_RATIO);

// --- explorer -----------------------------------------------------------------------------
// A floating directory navigator over the daemon's live workspace.browse, fuzzy-filtered as you
// type (the query ranks the current directory's entries). Enter/→ descends; ← goes to the parent;
// Esc closes. A ".." row and the daemon's own path both survive an empty query. `startPath` omitted
// roots at the daemon's default (home). The listing is one page — a directory with more entries
// shows a trailing non-selectable notice rather than silently truncating; cursor paging is future.
function openExplorer(startPath) {
  const state = { path: startPath || "", parent: null };

  const picker = ui.pick({
    title: () => state.path || "…",
    footer: "type to filter · ↵/→ enter · ← up · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.6,
    key: (e) => e.key,
    // Match on the entry name; the ".." and notice rows carry no name, so they drop out the moment
    // a query is typed (fuzzyRank keeps them only on an empty query) and navigation resumes on clear.
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
    client.workspaceBrowse(path != null ? { path } : {}).then(
      (res) => {
        state.path = res.path;
        state.parent = res.parent;

        const rows = [];
        if (res.parent != null) rows.push({ key: "..", up: true, dest: res.parent });
        for (const e of res.entries) {
          rows.push({ key: e.path, name: e.name, path: e.path, is_git_repo: e.is_git_repo });
        }

        if (res.next_cursor != null) rows.push({ key: "\x00more", notice: true, text: "… more entries not shown" });

        picker.content.query = ""; // a fresh level starts unfiltered
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
// A picker over the command registry: lists the commands available in the current context and
// runs the chosen one. Built on ui.pick — the same fuzzy finder as the explorer and session finder.

// Best-effort availability: run the predicate with no args, treating a throw as available so a
// command with an argument-injecting predicate is still listed.
function commandAvailable(cmd) {
  if (!cmd || !cmd.predicate) return true;

  try {
    const r = cmd.predicate();
    return Array.isArray(r) ? !!r[0] : !!r;
  } catch (_e) {
    return true;
  }
}

// The first stroke bound to `name`, for the palette's right-hand hint column.
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

// A session finder: fuzzy-search the sidebar's loaded sessions by title; accept marks and selects.
function openSessionFinder() {
  return ui.pick({
    title: "sessions",
    footer: "type to filter · ↵ select · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.5,
    items: sidebar.list.items,
    key: (r) => r.id,
    filterText: (r) => r.title,
    format: (r) => ({ text: r.title, right: activityMark(r.activity) }),
    onAccept: (r) => {
      sidebar.activeId = r.id;
      sidebar.list.selectedKey = r.id;
      chatSession.open(r.id);
    },
  });
}

// --- command line -------------------------------------------------------------------------
// A vim-style ":" line: matches a command's short name (after its last ":") exactly or by
// unique prefix, gated to commands available in the current context — ":q" quits, ":e" explores.
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
    if (hit) return null; // ambiguous prefix
    hit = names[short];
  }
  return hit;
}

// A single bottom row that edits a command word and runs it on Enter. Modal, so it owns every
// keystroke while open; Esc — or Backspace past the prompt — cancels.
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

    // Backspace past the empty prompt closes the line; otherwise editing (and its onChange, which
    // clears the error) goes to the shared buffer.
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
// Owns the local daemon lifecycle from config.daemon. The host has no setTimeout, so this service
// ticks: ready polls for drops, offline counts down and reconnects (autoConnect: false dials manually).
const READY_POLL_MS = 1000;
const RETRY_POLL_MS = 500;

const connection = {
  nextRetryAt: 0,

  onStart() {
    if (config.daemon.autoConnect === false) return;
    this.attempt();
  },

  attempt() {
    if (client.connectionState() !== "disconnected") return;

    this.nextRetryAt = 0;
    const d = config.daemon;
    const opts = { host: d.host, port: d.port };
    if (d.token) opts.token = d.token;

    try {
      client.connect(opts).then(
        () => {
          events.emit("daemon:ready");
          root.invalidate();
        },
        () => {
          this.scheduleRetry();
          root.invalidate();
        },
      );
    } catch (_e) {
      this.scheduleRetry();
    }

    root.invalidate();
  },

  scheduleRetry() {
    if (config.daemon.autoConnect === false) return;
    this.nextRetryAt = Date.now() + config.daemon.retryMs;
  },

  // Ready always polls (drop → UI). Offline polls when auto-reconnect is on or a countdown is live.
  needsTick() {
    const st = client.connectionState();
    if (st === "ready") return { periodMs: READY_POLL_MS };
    if (st === "connecting" || st === "closing") return { periodMs: RETRY_POLL_MS };
    if (config.daemon.autoConnect !== false || this.nextRetryAt > 0) {
      return { periodMs: RETRY_POLL_MS };
    }
    return null;
  },

  // Auto path only: arm a retry if none is pending, else dial when due. Manual mode never retries.
  tick() {
    if (client.connectionState() !== "disconnected") return;
    if (config.daemon.autoConnect === false) return;

    if (this.nextRetryAt === 0) {
      this.nextRetryAt = Date.now() + config.daemon.retryMs;
    } else if (Date.now() >= this.nextRetryAt) {
      this.attempt();
    }
  },
};

// Sidebar/main status: connected / connecting / offline with a retry countdown.
function connectionLabel() {
  const st = client.connectionState();
  if (st === "ready") return "connected";
  if (st === "connecting") return "connecting…";
  if (st === "closing") return "disconnecting…";

  if (connection.nextRetryAt > 0) {
    const secs = Math.max(0, Math.ceil((connection.nextRetryAt - Date.now()) / 1000));
    return "daemon off · retry " + secs + "s";
  }

  return "daemon off";
}

// --- commands + keymaps -------------------------------------------------------------------
// The stock commands and keybinds ship as a plugin, loading/unloading through the kernel like any
// extension. app:* act globally; focus:*/window:* drive the node tree.
plugins.use({
  name: "app-keys",
  apply(ctx) {
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

    // Global commands live on ctrl strokes so they never collide with typing into the composer;
    // bare keys stay text. Window nav is a ctrl+k prefix (works in every mode, even mid-typing),
    // leaving ctrl+w free for the composer's word-erase. The ":" line belongs to the vim layer.
    ctx.keymap({
      "ctrl+p": "ui:palette",
      "ctrl+f": "ui:sessions",
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

// Load vim at startup when the user opted in via yuke.js. Read at "start" so a yuke.js that sets
// config.vim (it loads after this module) is honored; :vim / vim:toggle flips it at runtime.
events.on("start", () => {
  if (config.vim && !plugins.get("vim")) plugins.use(vim);
});

// Exported so a user's yuke.js can reference the stock views and layout (swap, subclass, patch).
export { workspace, sidebar, chat, ChatView, SessionList, MainPane, openExplorer, openPalette, openSessionFinder, openCommandLine, connection };
