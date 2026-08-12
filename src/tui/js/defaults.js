// yuke:defaults — bundled default UI: a split shell (sidebar | main) with local daemon
// connect, command palette, ":" line, and a stub workspace explorer. A user's yuke.js layers
// on top (keymaps, prototype patches, view swaps). Session list / transcript / composer are
import { term } from "yuke:term";
import { command, keymap, style, clip, fill, text, strokeOf, View, root, quit, config } from "yuke:core";
import { ui } from "yuke:ui";
import { connect, connectionState } from "yuke:client";

// The ":" command line: prompt links to Normal, an unmatched word shows in red.
Object.assign(style.groups, {
  YukeCmdline: { link: "Normal" },
  YukeCmdlineErr: { fg: 203, bold: true },
});
style.invalidate();

// Stub explorer root until workspace.browse is wired.
const EXPLORER_ROOT = "/Users/xyaman/Work";

// Minimum sidebar width in cells; shrinks on very narrow terminals.
const SIDEBAR_MIN = 18;
const SIDEBAR_MAX = 36;
const SIDEBAR_FRAC = 0.3;

function paintRuleV(x, y, h, group) {
  if (h <= 0) return;
  for (let row = 0; row < h; row++) {
    text(x, y + row, "│", group);
  }
}

// Sidebar width for the current terminal; main gets the rest past a one-cell rule.
function layout(w, h) {
  if (w < 2) {
    return { sidebarW: w, mainX: w, mainW: 0, h: h };
  }

  let sidebarW = Math.floor(w * SIDEBAR_FRAC);
  if (sidebarW < SIDEBAR_MIN) sidebarW = Math.min(SIDEBAR_MIN, w - 1);
  if (sidebarW > SIDEBAR_MAX) sidebarW = SIDEBAR_MAX;
  if (sidebarW >= w) sidebarW = w - 1;

  const mainX = sidebarW + 1;
  const mainW = Math.max(0, w - mainX);
  return { sidebarW, mainX, mainW, h };
}

// --- app shell ----------------------------------------------------------------------------
// One root view: left session sidebar (empty until Phase 1), right main pane (empty until an
// open session). Focus is sidebar | main so Phase 1 can attach list vs transcript keys.
class AppView extends View {
  constructor() {
    super();
    this.focus = "sidebar"; // "sidebar" | "main"
  }

  get name() {
    return "app";
  }

  onKey(ev) {
    const s = strokeOf(ev);

    if (s === "tab") {
      this.focus = this.focus === "sidebar" ? "main" : "sidebar";
      return true;
    }

    return false;
  }

  draw() {
    const w = term.width;
    const h = term.height;
    fill(0, 0, w, h, "Normal");
    if (w <= 0 || h <= 0) return;

    const { sidebarW, mainX, mainW } = layout(w, h);
    this._drawSidebar(0, 0, sidebarW, h);
    if (mainX < w) {
      paintRuleV(mainX - 1, 0, h, "YukeRule");
      this._drawMain(mainX, 0, mainW, h);
    }
  }

  _drawSidebar(x, y, sw, h) {
    if (sw <= 0 || h <= 0) return;

    const pad = sw >= 4 ? 1 : 0;
    const iw = Math.max(0, sw - pad * 2);
    let row = y;

    if (row < y + h) {
      text(x + pad, row, clip("yuke", iw), "YukeBrand");
      row++;
    }

    if (row < y + h) {
      const st = "local · " + connectionLabel();
      text(x + pad, row, clip(st, iw), "YukeStatus");
      row++;
    }

    if (row < y + h) {
      text(x + pad, row, clip("─".repeat(iw), iw), "YukeRule");
      row++;
    }

    if (row < y + h) {
      const st = connectionState();
      const msg =
        st === "ready" ? "no sessions" : st === "connecting" || st === "closing" ? "…" : "not connected";
      text(x + pad, row, clip(msg, iw), "YukeEmpty");
      row++;
    }

    if (h > 0) {
      const hint = this.focus === "sidebar" ? "tab main · - explore · : " : "tab · - · :";
      text(x + pad, y + h - 1, clip(hint, iw), "YukeFooter");
    }
  }

  _drawMain(x, y, mw, h) {
    if (mw <= 0 || h <= 0) return;

    const pad = mw >= 4 ? 1 : 0;
    const iw = Math.max(0, mw - pad * 2);
    const st = connectionState();

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
      const left = this.focus === "main" ? "tab sidebar · space palette · : command" : "space palette · : command";
      text(x + pad, y + h - 1, clip(left, iw), "YukeFooter");
    }
  }
}

const app = new AppView();

// --- explorer -----------------------------------------------------------------------------
// A directory navigator over the daemon's workspace.browse shape. The data is stubbed here
// (a fake tree) until the daemon bridge lands; swapping `browse` for the real RPC is the only
// change. Entries are directories only (name, path, is_git_repo), paginated with a cursor.
const FS = {
  "/Users/xyaman": { parent: "/Users", dirs: [["Work", false], ["Documents", false]] },
  "/Users/xyaman/Work": {
    parent: "/Users/xyaman",
    dirs: [["yuke-odin", true], ["other-app", true], ["monorepo", false], ["scratch", false]],
  },
  "/Users/xyaman/Work/yuke-odin": {
    parent: "/Users/xyaman/Work",
    dirs: [["src", false], ["libs", false], ["docs", false], ["tools", false]],
  },
  "/Users/xyaman/Work/monorepo": {
    parent: "/Users/xyaman/Work",
    dirs: [["app-web", true], ["app-api", true], ["shared", false]],
  },
};

function browse(path) {
  const node = FS[path] || { parent: path.replace(/\/[^/]*$/, "") || "/", dirs: [] };
  return Promise.resolve({
    path: path,
    parent: node.parent,
    entries: node.dirs.map(([name, git]) => ({ name: name, path: path + "/" + name, is_git_repo: git })),
    next_cursor: null,
  });
}

// Open a floating directory navigator rooted at `startPath`. Enter descends (or, on a repo,
// would open it); "-" goes to the parent; Esc closes. A ".." row appears when a parent exists.
function openExplorer(startPath) {
  const state = { path: startPath, parent: null };

  const picker = ui.select([], {
    title: () => state.path,
    footer: "j/k · ↵ enter · - up · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.6,
    key: (e) => e.key,
    format: (e) =>
      e.up
        ? { text: "..", group: "UIDim" }
        : { text: e.name + "/", right: e.is_git_repo ? "git" : "" },
    onAccept: (e) => go(e.up ? e.dest : e.path),
    closeOnAccept: false,
    keymap: {
      "-": () => {
        if (state.parent != null) go(state.parent);
      },
    },
  });

  function go(path) {
    browse(path).then((res) => {
      state.path = res.path;
      state.parent = res.parent;

      const rows = [];
      if (res.parent != null) rows.push({ key: "..", up: true, dest: res.parent });
      for (const e of res.entries) {
        rows.push({ key: e.path, name: e.name, path: e.path, is_git_repo: e.is_git_repo });
      }

      picker.content.setItems(rows);
      root.invalidate();
    });
  }

  go(startPath);
  return picker;
}

// --- command palette ----------------------------------------------------------------------
// A picker over the command registry: lists the commands available in the current context and
// runs the chosen one. Built entirely on ui.select — the same primitive as the explorer.

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

  return ui.select(cmds, {
    title: "commands",
    footer: "j/k · ↵ run · esc close",
    border: "rounded",
    width: 0.5,
    height: 0.5,
    key: (c) => c.name,
    format: (c) => ({ text: c.name, right: c.hint }),
    onAccept: (c) => command.perform(c.name),
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
    this.text = "";
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
    text(0, y, clip(err ? this.error : ":" + this.text, w), err ? "YukeCmdlineErr" : "YukeCmdline");
  }

  cursor() {
    if (this.error) return null;

    return { x: Math.min(term.width - 1, 1 + this.text.length), y: term.height - 1, visible: true };
  }

  submit() {
    const word = this.text.trim();
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

    if (s === "backspace") {
      if (this.text === "") root.popOverlay(this);
      else this.text = this.text.slice(0, -1);
      this.error = "";
      return true;
    }

    // A printable char extends the word; any modifier past Shift means a shortcut, not text.
    if (ev.code === "char" && ev.char && ((ev.mods | 0) & ~1) === 0) {
      this.text += ev.char;
      this.error = "";
    }

    return true; // modal: consume every key
  }
}

function openCommandLine() {
  return root.pushOverlay(new CommandLine());
}

// --- daemon connection --------------------------------------------------------------------
// Owns the local daemon lifecycle. Target and retry policy come from config.daemon (set by
// defaults or defineConfig in yuke.js before start). The host has no setTimeout and does not
// push post-ready close into JS, so while auto-connect is on (or a session is live) this service
// ticks: ready → slow drop poll; offline → countdown + reconnect. autoConnect: false skips
// initial dial and auto-retry; :connect (app:connect) dials once manually.
const READY_POLL_MS = 1000;
const RETRY_POLL_MS = 500;

const connection = {
  nextRetryAt: 0,

  onStart() {
    if (config.daemon.autoConnect === false) return;
    this.attempt();
  },

  attempt() {
    if (connectionState() !== "disconnected") return;

    this.nextRetryAt = 0;
    const d = config.daemon;
    const opts = { host: d.host, port: d.port };
    if (d.token) opts.token = d.token;

    try {
      connect(opts).then(
        () => {
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
    const st = connectionState();
    if (st === "ready") return { periodMs: READY_POLL_MS };
    if (st === "connecting" || st === "closing") return { periodMs: RETRY_POLL_MS };
    if (config.daemon.autoConnect !== false || this.nextRetryAt > 0) {
      return { periodMs: RETRY_POLL_MS };
    }
    return null;
  },

  // Auto path only: arm a retry if none is pending, else dial when due. Manual mode never retries.
  tick() {
    if (connectionState() !== "disconnected") return;
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
  const st = connectionState();
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
command.add(null, {
  "app:quit": () => quit(),
  "ui:palette": () => openPalette(),
  "app:connect": () => connection.attempt(),
  "app:explorer": () => openExplorer(EXPLORER_ROOT),
});

keymap.add({
  "-": "app:explorer",
  " ": "ui:palette",
  ":": () => {
    openCommandLine();
    return true;
  },
});

root.setActive(app);
root.addService(connection);

// Exported so a user's yuke.js can reference the stock view (swap, subclass, or patch).
export { app, AppView, openExplorer, openPalette, openCommandLine, connection };
