// yuke:defaults — the bundled default UI: a session home screen and a placeholder shell,
// built on yuke:core as View subclasses with commands and keymaps. A user's yuke.js layers on
// top of this (adds keymaps, patches these prototypes, swaps the active view).
import { term } from "yuke:term";
import { command, keymap, style, clip, fill, text, strokeOf, View, root, quit } from "yuke:core";
import { ui, List, Transcript } from "yuke:ui";
import { connect, connectionState } from "yuke:client";

// The ":" command line: prompt links to Normal, an unmatched word shows in red.
Object.assign(style.groups, {
  YukeCmdline: { link: "Normal" },
  YukeCmdlineErr: { fg: 203, bold: true },
});
style.invalidate();

// Brand banner; falls back to plain "yuke" when the terminal is too narrow or short.
const YUKE_BANNER = [
  "██╗   ██╗██╗   ██╗██╗  ██╗███████╗",
  "╚██╗ ██╔╝██║   ██║██║ ██╔╝██╔════╝",
  " ╚████╔╝ ██║   ██║█████╔╝ █████╗  ",
  "  ╚██╔╝  ██║   ██║██╔═██╗ ██╔══╝  ",
  "   ██║   ╚██████╔╝██║  ██╗███████╗",
  "   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝",
];
const YUKE_BANNER_W = YUKE_BANNER[0].length;
const YUKE_BANNER_H = YUKE_BANNER.length;

// Blank rows above the block logo, given up before the logo itself when the header is short.
const BRAND_PAD_TOP = 1;

// Centered brand: block logo when it fits, else plain "yuke".
function paintBrand(w, y, rows, group) {
  if (rows <= 0 || w <= 0) return;

  if (rows >= YUKE_BANNER_H && w >= YUKE_BANNER_W) {
    const x = Math.floor((w - YUKE_BANNER_W) / 2);
    for (let i = 0; i < YUKE_BANNER_H; i++) {
      text(x, y + i, YUKE_BANNER[i], group);
    }
    return;
  }

  const word = "yuke";
  const x = Math.max(0, Math.floor((w - word.length) / 2));
  text(x, y, word, group);
}

function paintCentered(y, s, w, group) {
  s = String(s);
  if (w <= 0 || !s) return;
  const clipped = clip(s, w);
  const x = Math.max(0, Math.floor((w - clipped.length) / 2));
  text(x, y, clipped, group);
}

// Spinner shown on a running session; its period is also the repaint rate while anything runs.
const SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
const SPINNER_PERIOD_MS = 100;

function spinnerDraw(x, y, phase) {
  text(x, y, SPINNER_FRAMES[phase], "YukeSpinner");
}

// Dummy catalog (no daemon). Shapes mirror wire Session-ish fields.
const THIS_WS = {
  id: "ws_me",
  root: "/Users/xyaman/Work/yuke-odin",
};

const OTHER_WS = [
  { id: "ws_other", root: "/Users/xyaman/Work/other-app" },
  { id: "ws_mono", root: "/Users/xyaman/Work/monorepo" },
];

const CURRENT_LIMIT = 5;
const OTHERS_WINDOW_MS = 30 * 60 * 1000;
const DEFAULT_PROFILE = "default";
const DEFAULT_MODEL = "opus";

let nowMs = Date.now();
let nextId = 100;

let sessions = [];

function seedDummy() {
  nowMs = Date.now();
  sessions = [
    { id: "s1", workspace_id: THIS_WS.id, title: "Fix SIGWINCH under tmux", updated_at_ms: nowMs - 12 * 60e3, running: false, profile: "default", model: "opus", message_count: 14 },
    { id: "s2", workspace_id: THIS_WS.id, title: "Session list UI sketch", updated_at_ms: nowMs - 60 * 60e3, running: false, profile: "default", model: "sonnet", message_count: 8 },
    { id: "s3", workspace_id: THIS_WS.id, title: "Wire protocol cleanup", updated_at_ms: nowMs - 3 * 60 * 60e3, running: false, profile: "strict", model: "opus", message_count: 32 },
    { id: "s4", workspace_id: THIS_WS.id, title: "QuickJS host polish", updated_at_ms: nowMs - 24 * 60 * 60e3, running: false, profile: "default", model: "haiku", message_count: 5 },
    { id: "s5", workspace_id: THIS_WS.id, title: "termdrive relay review", updated_at_ms: nowMs - 2 * 24 * 60 * 60e3, running: false, profile: "default", model: "opus", message_count: 21 },
    { id: "s6", workspace_id: THIS_WS.id, title: "Older idle session (hidden by cap)", updated_at_ms: nowMs - 10 * 24 * 60 * 60e3, running: false, profile: "default", model: "opus", message_count: 3 },
    { id: "s7", workspace_id: "ws_other", title: "Investigate flaky CI", updated_at_ms: nowMs - 4 * 60e3, running: true, profile: "ci", model: "sonnet", message_count: 6 },
    { id: "s8", workspace_id: "ws_mono", title: "Agent tools permissions", updated_at_ms: nowMs - 25 * 60e3, running: false, profile: "default", model: "opus", message_count: 11 },
    { id: "s9", workspace_id: "ws_mono", title: "Stale elsewhere (hidden by window)", updated_at_ms: nowMs - 2 * 60 * 60e3, running: false, profile: "default", model: "opus", message_count: 2 },
  ];
}

function wsById(id) {
  if (id === THIS_WS.id) return THIS_WS;
  for (let i = 0; i < OTHER_WS.length; i++) {
    if (OTHER_WS[i].id === id) return OTHER_WS[i];
  }
  return { id: id, root: id };
}

function wsLabel(root) {
  if (!root) return "?";
  const parts = String(root).split("/").filter(Boolean);
  if (parts.length === 0) return root;
  if (parts.length === 1) return parts[0];
  return parts[parts.length - 2] + "/" + parts[parts.length - 1];
}

const AGO_UNITS = [
  [31536000, "y"],
  [2592000, "mo"],
  [604800, "w"],
  [86400, "d"],
  [3600, "h"],
  [60, "m"],
];

function agoLabel(deltaMs) {
  const s = Math.floor(Math.max(0, deltaMs) / 1000);
  if (s < 60) return "now";

  for (let i = 0; i < AGO_UNITS.length; i++) {
    const n = Math.floor(s / AGO_UNITS[i][0]);
    if (n >= 1) return n + AGO_UNITS[i][1];
  }
}

function sessionMeta(s) {
  const parts = [];
  if (s.profile) parts.push(s.profile);
  if (s.model) parts.push(s.model);
  parts.push(agoLabel(nowMs - s.updated_at_ms));
  return parts.join(" · ");
}

// Catalog slices used by header counts + list.
function catalogSlices() {
  nowMs = Date.now();

  const current = sessions
    .filter((s) => s.workspace_id === THIS_WS.id)
    .sort((a, b) => b.updated_at_ms - a.updated_at_ms || a.title.localeCompare(b.title));

  let idle = 0;
  const here = [];
  for (let i = 0; i < current.length; i++) {
    const s = current[i];
    if (s.running) {
      here.push(s);
    } else {
      idle++;
      if (idle <= CURRENT_LIMIT) here.push(s);
    }
  }

  const others = sessions
    .filter((s) => {
      if (s.workspace_id === THIS_WS.id) return false;
      if (s.running) return true;
      return nowMs - s.updated_at_ms < OTHERS_WINDOW_MS;
    })
    .sort((a, b) => {
      if (a.running !== b.running) return a.running ? -1 : 1;
      return b.updated_at_ms - a.updated_at_ms || a.title.localeCompare(b.title);
    });

  return { here: here, others: others };
}

// Logical list items (selection walks sessions only).
function buildItems(slices) {
  const { here, others } = slices || catalogSlices();
  const items = [];

  items.push({ kind: "section", text: "here · " + here.length });
  if (here.length === 0) {
    items.push({ kind: "empty", text: "no sessions yet — press n" });
  } else {
    for (let i = 0; i < here.length; i++) {
      items.push({ kind: "session", session: here[i] });
    }
  }

  if (others.length > 0) {
    items.push({ kind: "blank" });
    items.push({ kind: "section", text: "elsewhere · " + others.length });

    const order = [];
    for (let i = 0; i < others.length; i++) {
      const id = others[i].workspace_id;
      if (order.indexOf(id) < 0) order.push(id);
    }
    for (let oi = 0; oi < order.length; oi++) {
      const wid = order[oi];
      if (oi > 0) items.push({ kind: "blank" });
      items.push({ kind: "workspace", text: wsLabel(wsById(wid).root) });
      for (let i = 0; i < others.length; i++) {
        if (others[i].workspace_id === wid) {
          items.push({ kind: "session", session: others[i] });
        }
      }
    }
  }

  return items;
}

// Flatten to paint lines (session → title + meta).
function flattenLines(items) {
  const lines = [];
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    if (it.kind === "session") {
      lines.push({ kind: "session_title", session: it.session });
      lines.push({ kind: "session_meta", session: it.session });
    } else {
      lines.push(it);
    }
  }
  return lines;
}

// --- shared selection state ---------------------------------------------------------------
// Selection and scroll live in a List (yuke:ui). Its items are the flattened paint lines;
// only session_title lines are selectable, and the selection is keyed by session id, so a
// re-sort between paints never slides it. The list owns scroll-to-visible; HomeView renders
// the rows itself using its `scroll`. `selected()` is a session's title line — `.session` is
// the session.
let openSession = null;
let tickPhase = 0;

const homeList = new List({
  key: (line) => (line.session ? line.session.id : null),
  isSelectable: (line) => line.kind === "session_title",
});

function selectedSession() {
  const line = homeList.selected();
  return line ? line.session : null;
}

function openSelected() {
  const s = selectedSession();
  if (!s) return;

  openSession = { id: s.id, title: s.title };
  root.setActive(shell);
}

function createAndOpen() {
  nowMs = Date.now();
  const id = "s_" + nextId++;
  const s = {
    id: id,
    workspace_id: THIS_WS.id,
    title: "Untitled",
    updated_at_ms: nowMs,
    running: false,
    profile: DEFAULT_PROFILE,
    model: DEFAULT_MODEL,
    message_count: 0,
  };
  sessions.unshift(s);
  openSession = { id: s.id, title: s.title };
  homeList.selectedKey = s.id;
  root.setActive(shell);
}

function paintRule(y, padX, innerW) {
  if (innerW <= 0) return;
  text(padX, y, "─".repeat(innerW), "YukeRule");
}

// Header rows granted for a wanted height, keeping at least one body row when possible.
function headerFit(want, h, footerRows) {
  if (h - footerRows >= 2) return Math.min(want, h - footerRows - 1);
  return Math.min(want, Math.max(0, h - footerRows));
}

// Layout: footer always last row; header collapses so body never shares footer cells.
function homeLayout(w, h) {
  const footerRows = h > 0 ? 1 : 0;
  const wantBanner = w >= YUKE_BANNER_W;

  let padTop = wantBanner ? BRAND_PAD_TOP : 0;
  let brandH = wantBanner ? YUKE_BANNER_H : 1;
  let headerH = headerFit(padTop + brandH + 4, h, footerRows);

  if (wantBanner && headerH < padTop + YUKE_BANNER_H) {
    padTop = 0;
    headerH = headerFit(brandH + 4, h, footerRows);
  }

  if (wantBanner && headerH < YUKE_BANNER_H) {
    brandH = 1;
    headerH = headerFit(brandH + 4, h, footerRows);
  }

  const bodyTop = headerH;
  const bodyBot = h - footerRows - 1;
  const bodyH = Math.max(0, bodyBot - bodyTop + 1);
  return { headerH, bodyTop, bodyH, footerRows, brandH, padTop };
}

// --- home view ----------------------------------------------------------------------------
class HomeView extends View {
  get name() {
    return "home";
  }

  tick() {
    tickPhase = (tickPhase + 1) % SPINNER_FRAMES.length;
  }

  needsTick() {
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].running) return { periodMs: SPINNER_PERIOD_MS };
    }
    return null;
  }

  // Selection movement rides the shared list vocabulary (j/k, ctrl+d/u, gg, G); actions (open,
  // new, explore) stay command-bound so they show in the palette and the ":" line.
  onKey(ev) {
    return homeList.onKey(ev);
  }

  draw() {
    const w = term.width;
    const h = term.height;
    const slices = catalogSlices();
    const items = buildItems(slices);
    const lines = flattenLines(items);
    const here = slices.here;
    const others = slices.others;

    homeList.setItems(lines);

    const padX = w >= 48 ? 3 : w >= 32 ? 2 : 1;
    const { headerH, bodyTop, bodyH, brandH, padTop } = homeLayout(w, h);
    const innerW = Math.max(0, w - padX * 2);

    homeList.ensureVisible(bodyH);

    fill(0, 0, w, h, "Normal");

    if (headerH > padTop) {
      paintBrand(w, padTop, Math.min(brandH, headerH - padTop), "YukeBrand");
    }

    let y = padTop + brandH;
    if (headerH > y) {
      const status = here.length + " here · " + others.length + " elsewhere · " + connectionLabel();
      paintCentered(y, status, w, "YukeStatus");
      y++;
    }
    if (headerH > y) {
      paintCentered(y, THIS_WS.root, w, "YukeHeader");
      y++;
    }
    if (headerH > y) {
      paintRule(y, padX, innerW);
      y++;
    }

    for (let row = 0; row < bodyH; row++) {
      const li = homeList.scroll + row;
      if (li >= lines.length) break;
      const line = lines[li];
      const screenY = bodyTop + row;

      if (line.kind === "blank") continue;

      if (line.kind === "section") {
        text(padX, screenY, clip(line.text, innerW), "YukeSection");
        continue;
      }

      if (line.kind === "workspace") {
        text(padX, screenY, clip(line.text, innerW), "YukeWorkspace");
        continue;
      }

      if (line.kind === "empty") {
        text(padX + 2, screenY, clip(line.text, Math.max(0, innerW - 2)), "YukeEmpty");
        continue;
      }

      const s = line.session;
      const isSel = s.id === homeList.selectedKey;
      if (isSel && innerW > 0) fill(padX, screenY, innerW, 1, "YukeSessionSel");

      const contentX = padX + 3;
      const contentW = Math.max(0, w - padX - 1 - contentX);

      if (line.kind === "session_title") {
        if (s.running) spinnerDraw(padX + 1, screenY, tickPhase);
        text(contentX, screenY, clip(s.title, contentW), isSel ? "YukeSessionSel" : "YukeSession");
        continue;
      }

      if (line.kind === "session_meta") {
        text(contentX, screenY, clip(sessionMeta(s), contentW), isSel ? "YukeSessionMetaSel" : "YukeSessionMeta");
        continue;
      }
    }

    if (h > 0) {
      const left = "j/k · ↵ open · n new · - explore · : command";
      const right = w + "×" + h;
      text(padX, h - 1, clip(left, innerW), "YukeFooter");
      if (innerW > left.length + right.length + 2) {
        text(w - padX - right.length, h - 1, right, "YukeFooter");
      }
    }
  }
}

// --- shell view ---------------------------------------------------------------------------
// A stubbed session transcript for exercising the Transcript pager without a daemon: seeded
// user/assistant text messages, plus a keyboard-toggled fake stream that appends words to the
// last assistant message so follow-bottom, re-wrap, and resize reflow can be tested live.
const LOREM =
  "The quick brown fox jumps over the lazy dog. Word wrapping has to stay cell-accurate for wide 漢字 and emoji 😊 runs. " +
  "Paragraphs wrap greedily at spaces; a single word longer than the width hard-breaks by grapheme cluster. ";

const STREAM_WORDS = "streaming a delta here appends one token at a time to watch the tail follow the bottom edge".split(" ");
let streamPhase = 0;

function stubMessages() {
  const msgs = [];
  for (let i = 0; i < 150; i++) {
    msgs.push({ type: "user", id: "u" + i, rev: 0, content: [{ type: "text", text: "Question " + i + ": " + LOREM.slice(0, 30 + ((i * 37) % 160)) }] });
    msgs.push({ type: "assistant", id: "a" + i, rev: 0, content: [{ type: "text", text: "Answer " + i + ". " + LOREM.repeat(1 + (i % 3)) }] });
  }
  return msgs;
}

class ShellView extends View {
  constructor() {
    super();
    this.transcript = new Transcript();
    this.streaming = false;
    this._seeded = false;
  }

  get name() {
    return "shell";
  }

  _ensure() {
    if (this._seeded) return;
    this.transcript.setMessages(stubMessages());
    this._seeded = true;
  }

  needsTick() {
    return this.streaming ? { periodMs: 60 } : null;
  }

  tick() {
    if (!this.streaming) return;

    const msgs = this.transcript.messages;
    const last = msgs[msgs.length - 1];
    if (last && last.type === "assistant") {
      last.content[0].text += " " + STREAM_WORDS[streamPhase++ % STREAM_WORDS.length];
      last.rev++;
      this.transcript.touch();
    }
  }

  // Scroll through every position painting each frame, to time worst-case scroll throughput
  // (layout is cached, so this measures paint + buffer diff + flush).
  runBenchmark() {
    const pager = this.transcript.pager;
    const saved = { scroll: pager.scroll, stuck: pager.stuck };
    const span = Math.max(1, pager._maxScroll());
    const N = 1000;

    pager.stuck = false;
    const t0 = Date.now();
    for (let i = 0; i < N; i++) {
      pager.scroll = i % span;
      root.draw();
    }
    const dt = Math.max(1, Date.now() - t0);

    pager.scroll = saved.scroll;
    pager.stuck = saved.stuck;
    this.benchFps = Math.round((N * 1000) / dt);
    this.benchMs = (dt / N).toFixed(2);
  }

  draw() {
    this._ensure();

    const w = term.width;
    const h = term.height;
    const title = openSession ? openSession.title : "session";
    const padX = w >= 48 ? 3 : w >= 32 ? 2 : 1;
    const innerW = Math.max(0, w - padX * 2);
    const footerY = h > 0 ? h - 1 : 0;
    const bodyTop = 3;
    const bodyH = Math.max(0, footerY - bodyTop);

    fill(0, 0, w, h, "Normal");
    if (h > 0) text(padX, 0, "yuke", "YukeBrand");
    if (h > 1) text(padX, 1, clip(title, innerW), "YukeShellTitle");
    if (h > 2) paintRule(2, padX, innerW);

    if (bodyH > 0) this.transcript.draw({ x: padX, y: bodyTop, w: innerW, h: bodyH });

    if (h > 0) {
      const left = "j/k · ^d/^u · g/G · s stream" + (this.streaming ? " ●" : "") + " · b bench · esc back · : command";
      const bench = this.benchFps ? this.benchFps + "fps " + this.benchMs + "ms · " : "";
      const right = bench + this.transcript.pager.rows.length + "rows " + w + "×" + h;
      text(padX, footerY, clip(left, innerW), "YukeFooter");
      if (innerW > left.length + right.length + 2) {
        text(w - padX - right.length, footerY, right, "YukeStatus");
      }
    }
  }

  onKey(ev) {
    switch (strokeOf(ev)) {
      case "s":
        this.streaming = !this.streaming;
        return true;
      case "b":
        this.runBenchmark();
        return true;
    }

    return this.transcript.onKey(ev);
  }
}

const home = new HomeView();
const shell = new ShellView();

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

// --- commands + keymaps -------------------------------------------------------------------
command.add(null, {
  "app:quit": () => quit(),
  "ui:palette": () => openPalette(),
});

command.add("home", {
  "home:new": () => createAndOpen(),
  "home:open": () => openSelected(),
  "home:explorer": () => openExplorer("/Users/xyaman/Work"),
});

command.add("shell", {
  "shell:back": () => {
    openSession = null;
    root.setActive(home);
  },
});

// Selection/scroll strokes are owned by the widgets (List/Pager); the keymap binds actions.
keymap.add({
  "n": "home:new",
  "enter": "home:open",
  "-": "home:explorer",
  "esc": "shell:back",
  " ": "ui:palette",
  ":": () => {
    openCommandLine();
    return true;
  },
});

// --- daemon connection --------------------------------------------------------------------
// Owns the local daemon lifecycle: connect on start, retry every RETRY_MS while down. The host
// has no setTimeout and does not push post-ready close into JS, so this service always ticks:
// while ready it is a slow liveness poll (drop → schedule retry); while down it advances the
// header countdown and reconnects. Views read connectionState()/connectionLabel(). Target is
// fixed until applyConfig lands.
const DAEMON = { host: "127.0.0.1", port: 9853 };
const RETRY_MS = 5000;
const READY_POLL_MS = 1000; // drop detection; host has no connection-change callback yet
const RETRY_POLL_MS = 500; // countdown label + reconnect deadline

const connection = {
  nextRetryAt: 0,

  onStart() {
    this.attempt();
  },

  attempt() {
    if (connectionState() !== "disconnected") return;

    this.nextRetryAt = 0;
    try {
      connect(DAEMON).then(
        () => {
          root.invalidate();
        },
        () => {
          this.nextRetryAt = Date.now() + RETRY_MS;
          root.invalidate();
        },
      );
    } catch (_e) {
      this.nextRetryAt = Date.now() + RETRY_MS;
    }

    root.invalidate();
  },

  // Always arm ticks: ready needs a heartbeat (no host drop event); offline needs the countdown.
  needsTick() {
    const ms = connectionState() === "ready" ? READY_POLL_MS : RETRY_POLL_MS;
    return { periodMs: ms };
  },

  // Disconnected: arm a retry if none is pending (failed attempt or live drop), else dial when due.
  // Connecting/ready/closing: no-op; the next disconnected tick will schedule.
  tick() {
    if (connectionState() !== "disconnected") return;

    if (this.nextRetryAt === 0) {
      this.nextRetryAt = Date.now() + RETRY_MS;
    } else if (Date.now() >= this.nextRetryAt) {
      this.attempt();
    }
  },
};

// Header status: connected / connecting / offline with a retry countdown.
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

seedDummy();
root.setActive(home);
root.addService(connection);

// Exported so a user's yuke.js can reference the stock views (swap, subclass, or patch).
export { home, shell, HomeView, ShellView };
