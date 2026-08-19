// yuke:core — the client's editor core, imported by the default UI and the user's yuke.js. Every
// extension point is a mutable exported object or class prototype; plugins extend by mutating them.
import { term } from "yuke:term";

// --- config -------------------------------------------------------------------------------
// Plain mutable tunables. Plugins namespace under config.plugins.<name>; product settings go
// through defineConfig or by mutating config.daemon before start — connection reads them at dial.
export const config = {
  plugins: Object.create(null),
  daemon: {
    host: "127.0.0.1",
    port: 9853,
    autoConnect: true,
    retryMs: 5000,
    // token: omit on loopback; set when the front door requires a bearer
  },
};

// Declarative entry for yuke.js: merges into config and returns the input so `export default
// defineConfig({…})` works. Unknown keys throw; a broken user file is non-fatal at the host.
export function defineConfig(partial) {
  if (partial == null || typeof partial !== "object" || Array.isArray(partial)) {
    throw new TypeError("defineConfig expects a config object");
  }

  for (const key of Object.keys(partial)) {
    if (key !== "daemon") {
      throw new TypeError("defineConfig: unknown key " + key);
    }
  }

  if (partial.daemon !== undefined) {
    applyDaemonConfig(partial.daemon);
  }

  return partial;
}

// Validate the whole partial first, then assign once — a throw must not leave config half-applied
// (yuke.js failures are non-fatal, so a partial dial target would silently stick).
function applyDaemonConfig(d) {
  if (d == null || typeof d !== "object" || Array.isArray(d)) {
    throw new TypeError("defineConfig.daemon expects an object");
  }

  for (const key of Object.keys(d)) {
    switch (key) {
      case "host":
      case "port":
      case "autoConnect":
      case "retryMs":
      case "token":
        break;
      default:
        throw new TypeError("defineConfig.daemon: unknown key " + key);
    }
  }

  const patch = {};

  if (d.host !== undefined) {
    if (typeof d.host !== "string" || d.host === "") {
      throw new TypeError("daemon.host must be a non-empty string");
    }
    patch.host = d.host;
  }

  if (d.port !== undefined) {
    const p = d.port;
    if (typeof p !== "number" || !Number.isFinite(p) || p !== (p | 0) || p < 1 || p > 65535) {
      throw new TypeError("daemon.port must be an integer 1..65535");
    }
    patch.port = p;
  }

  if (d.autoConnect !== undefined) {
    if (typeof d.autoConnect !== "boolean") {
      throw new TypeError("daemon.autoConnect must be a boolean");
    }
    patch.autoConnect = d.autoConnect;
  }

  if (d.retryMs !== undefined) {
    const ms = d.retryMs;
    if (typeof ms !== "number" || !Number.isFinite(ms) || ms !== (ms | 0) || ms < 1) {
      throw new TypeError("daemon.retryMs must be a positive integer");
    }
    patch.retryMs = ms;
  }

  if (d.token !== undefined) {
    if (typeof d.token !== "string") {
      throw new TypeError("daemon.token must be a string");
    }
    patch.token = d.token;
  }

  Object.assign(config.daemon, patch);
}

// --- style: highlight groups over a palette -----------------------------------------------
// A group is a style ({ fg?, bg?, bold?, … } over palette names) or a { link } to another
// group. Themes mutate `palette`/`groups` then call style.invalidate() to drop the cache.
export const style = {
  palette: {
    bg: "black",
    fg: "white",
    muted: "dark_gray",
    accent: "cyan",
    sel: 238,
    rule: 236,
  },
  groups: {
    Normal: { fg: "fg", bg: "bg" },
    Comment: { fg: "muted" },
    YukeBrand: { fg: "accent", bold: true },
    YukeHeader: { link: "Comment" },
    YukeFooter: { link: "Comment" },
    YukeStatus: { fg: "muted" },
    YukeRule: { fg: "rule", bg: "bg" },
    // Session list / selection (Phase 1 sidebar rows).
    YukeSession: { link: "Normal" },
    YukeSessionSel: { fg: "fg", bg: "sel" },
    YukeSessionMeta: { fg: "muted" },
    YukeSessionMetaSel: { fg: "muted", bg: "sel" },
    YukeEmpty: { fg: "muted" },
    YukeHint: { fg: "muted" },
  },
  _cache: Object.create(null),
  // Concrete style object for a group name, resolved once and cached until invalidate().
  resolve(name) {
    const cached = this._cache[name];
    if (cached) return cached;

    let def = this.groups[name];
    while (def && def.link) def = this.groups[def.link];

    const out = {};
    if (def) {
      if (def.bg !== undefined) out.bg = this.palette[def.bg] !== undefined ? this.palette[def.bg] : def.bg;
      if (def.bold) out.bold = true;
      if (def.dim) out.dim = true;
      if (def.italic) out.italic = true;
      if (def.underline) out.underline = true;
    }
    const fg = def && def.fg !== undefined ? def.fg : "fg";
    out.fg = this.palette[fg] !== undefined ? this.palette[fg] : fg;

    this._cache[name] = out;
    return out;
  },
  invalidate() {
    this._cache = Object.create(null);
  },
};

// Draw helpers that paint by group name, resolving through the theme so a live theme swap just
// works. Views paint through these rather than term.fill/term.text directly.
export function fill(x, y, w, h, group) {
  term.fill(x, y, w, h, style.resolve(group));
}

export function text(x, y, s, group) {
  term.text(x, y, s, style.resolve(group));
}

// Trim `s` to `max` display columns (cell-accurate via term.graphemes, so a wide/astral glyph
// costs its real width). Adds a one-cell ellipsis when truncated, unless max is 1.
export function clip(s, max) {
  if (max <= 0) return "";
  s = String(s);
  if (term.measure(s) <= max) return s;

  const ell = max > 1 ? 1 : 0;
  const budget = max - ell;
  const gs = term.graphemes(s);
  let cut = 0;
  let w = 0;
  for (let k = 0; k < gs.length; k += 3) {
    if (w + gs[k + 2] > budget) break;
    w += gs[k + 2];
    cut = gs[k] + gs[k + 1];
  }

  return s.slice(0, cut) + (ell ? "…" : "");
}

// Word-wrap `s` to lines no wider than `width` cells. Explicit "\n" force breaks; runs of
// spaces collapse to one at a wrap; a word wider than `width` hard-breaks by grapheme cluster.
export function wrap(s, width) {
  s = String(s);
  if (width <= 0) return [""];

  const lines = [];
  for (const para of s.split("\n")) {
    wrapParagraph(para, width, lines);
  }

  return lines;
}

// Non-space grapheme runs with their cell widths; spaces delimit, blank runs vanish.
function splitWords(para) {
  const gs = term.graphemes(para);
  const words = [];
  let text = "";
  let w = 0;
  for (let k = 0; k < gs.length; k += 3) {
    const ch = para.slice(gs[k], gs[k] + gs[k + 1]);
    if (ch === " ") {
      if (text) words.push({ text, w });
      text = "";
      w = 0;
    } else {
      text += ch;
      w += gs[k + 2];
    }
  }
  if (text) words.push({ text, w });

  return words;
}

// Split a too-wide token into pieces each within `width` (last piece is the remainder). A lone
// cluster wider than `width` still stands alone — a grapheme is never split.
function hardBreak(text, width) {
  const gs = term.graphemes(text);
  const pieces = [];
  let piece = "";
  let w = 0;
  for (let k = 0; k < gs.length; k += 3) {
    if (w + gs[k + 2] > width && piece !== "") {
      pieces.push({ text: piece, w });
      piece = "";
      w = 0;
    }
    piece += text.slice(gs[k], gs[k] + gs[k + 1]);
    w += gs[k + 2];
  }
  pieces.push({ text: piece, w });

  return pieces;
}

function wrapParagraph(para, width, out) {
  const words = splitWords(para);
  if (words.length === 0) {
    out.push("");
    return;
  }

  let line = "";
  let lineW = 0;
  for (const word of words) {
    if (line !== "" && lineW + 1 + word.w > width) {
      out.push(line);
      line = "";
      lineW = 0;
    }

    if (word.w > width) {
      const pieces = hardBreak(word.text, width);
      for (let i = 0; i < pieces.length - 1; i++) out.push(pieces[i].text);
      line = pieces[pieces.length - 1].text;
      lineW = pieces[pieces.length - 1].w;
    } else {
      const sep = line === "" ? 0 : 1;
      line += (sep ? " " : "") + word.text;
      lineW += sep + word.w;
    }
  }
  out.push(line);
}

// --- commands -----------------------------------------------------------------------------
// A command is { predicate, perform }. The predicate returns a boolean, or [available, ...args]
// whose tail becomes perform's arguments. A string predicate matches the active view's name.
export const command = {
  map: Object.create(null),

  // Register commands under one predicate. The disposer removes exactly the names it added (while
  // they still point here), so a plugin's commands vanish on unload.
  add(predicate, map) {
    const pred = normalizePredicate(predicate);
    const added = [];
    for (const name in map) {
      const entry = { predicate: pred, perform: map[name] };
      this.map[name] = entry;
      added.push([name, entry]);
    }

    return () => {
      for (const [name, entry] of added) {
        if (this.map[name] === entry) delete this.map[name];
      }
    };
  },

  // Run `name` if its predicate allows. Returns whether it performed.
  perform(name, ...args) {
    const cmd = this.map[name];
    if (!cmd) return false;

    const res = cmd.predicate ? cmd.predicate(...args) : true;
    const avail = Array.isArray(res) ? res[0] : res;
    if (!avail) return false;

    const extra = Array.isArray(res) && res.length > 1 ? res.slice(1) : args;
    cmd.perform(...extra);
    return true;
  },
};

function normalizePredicate(predicate) {
  if (predicate == null) return null;
  if (typeof predicate === "string") {
    return () => (root.active && root.active.name === predicate ? [true, root.active] : [false]);
  }

  return predicate;
}

// --- keymap -------------------------------------------------------------------------------
// Each key maps to ordered handlers tried until one matches; add() prepends so later bindings win.
// A key may chord as "prefix stroke" (e.g. "ctrl+w h"): the prefix arms, the next stroke completes.
export const keymap = {
  map: Object.create(null),
  prefixes: Object.create(null), // first stroke of any chord -> true
  pending: null, // armed prefix awaiting its completion stroke

  // Bind strokes to handlers. The disposer splices out exactly the handlers it added (by identity)
  // and rebuilds the prefix set, so a plugin's binds vanish without disturbing others.
  add(bindings, overwrite) {
    const added = [];
    for (const seq in bindings) {
      const key = normalizeSeq(seq);
      const value = bindings[seq];
      const list = Array.isArray(value) ? value.slice() : [value];
      if (overwrite || !this.map[key]) {
        this.map[key] = list;
      } else {
        this.map[key] = list.concat(this.map[key]);
      }

      for (const h of list) added.push([key, h]);
    }

    this._rebuildPrefixes();

    return () => {
      for (const [key, h] of added) {
        const cur = this.map[key];
        if (!cur) continue;

        const i = cur.indexOf(h);
        if (i >= 0) cur.splice(i, 1);
        if (cur.length === 0) delete this.map[key];
      }

      this._rebuildPrefixes();
    };
  },

  // Recompute the first-stroke-of-a-chord set from the live bindings, so a removed chord leaves no
  // stale prefix. Clearing a now-unbacked armed prefix stops it from swallowing the next key.
  _rebuildPrefixes() {
    this.prefixes = Object.create(null);
    for (const key in this.map) {
      const sp = key.indexOf(" ");
      if (sp > 0) this.prefixes[key.slice(0, sp)] = true;
    }

    if (this.pending && !this.prefixes[this.pending]) this.pending = null;
  },

  // Try the bound commands for this key event; returns whether one handled it. A pending prefix
  // consumes its follow-up whether or not the chord resolves.
  onKey(ev) {
    const s = strokeOf(ev);
    if (!s) return false;

    if (this.pending) {
      const prefix = this.pending;
      this.pending = null;
      // Accept the completion with or without a held modifier (ctrl+w h and ctrl+w ctrl+h).
      this._perform(this.map[prefix + " " + s] || this.map[prefix + " " + stripCtrl(s)], ev);
      return true;
    }

    if (this.prefixes[s]) {
      this.pending = s;
      return true;
    }

    return this._perform(this.map[s], ev);
  },

  _perform(cmds, ev) {
    if (!cmds) return false;

    for (const c of cmds) {
      if (typeof c === "function") {
        if (c(ev) !== false) return true;
      } else if (command.perform(c, ev)) {
        return true;
      }
    }
    return false;
  },
};

// Normalize a binding key: each space-separated stroke canonicalized, rejoined with one space. A
// whitespace-only key is the space stroke itself, not a chord, so it is normalized whole.
function normalizeSeq(seq) {
  const s = String(seq);
  if (s.trim() === "") return normalizeStroke(s);

  return s
    .trim()
    .split(/\s+/)
    .map(normalizeStroke)
    .join(" ");
}

// Drop a leading ctrl so a chord completion matches whether or not ctrl stayed held.
function stripCtrl(stroke) {
  return stroke.indexOf("ctrl+") === 0 ? stroke.slice(5) : stroke;
}

// Modifier bit layout from the host (js.odin): Shift=1, Alt=2, Ctrl=4, Super=8.
const MOD_SHIFT = 1;
const MOD_ALT = 2;
const MOD_CTRL = 4;
const MOD_SUPER = 8;

// The one place canonical stroke ordering lives: modifiers (ctrl, alt, super, shift) then the key
// token, "+"-joined. Both strokeOf and normalizeStroke route through it so they cannot disagree.
function joinStroke(mods, token) {
  const parts = [];
  if (mods.ctrl) parts.push("ctrl");
  if (mods.alt) parts.push("alt");
  if (mods.super) parts.push("super");
  if (mods.shift) parts.push("shift");
  parts.push(token);
  return parts.join("+");
}

export function strokeOf(ev) {
  const m = ev.mods | 0;
  let token;
  let shift = (m & MOD_SHIFT) !== 0;
  if (ev.code === "char") {
    token = (ev.char || "").toLowerCase();
    shift = false;
  } else {
    token = ev.code;
  }
  if (!token) return "";

  return joinStroke({ ctrl: !!(m & MOD_CTRL), alt: !!(m & MOD_ALT), super: !!(m & MOD_SUPER), shift }, token);
}

function normalizeStroke(stroke) {
  const parts = String(stroke).toLowerCase().split("+");
  const token = parts.pop();
  const mods = { ctrl: false, alt: false, super: false, shift: false };
  for (const p of parts) {
    if (p === "control") mods.ctrl = true;
    else if (p in mods) mods[p] = true;
  }
  return joinStroke(mods, token);
}

// --- events -------------------------------------------------------------------------------
// A small synchronous event bus. `emit` isolates a throwing listener via onError; `bail` runs
// until a listener returns a non-nullish, non-false value and returns it. `on` returns a disposer.
export class Emitter {
  constructor() {
    this._hooks = Object.create(null); // name -> handler[]
    this.onError = null; // (err, name) => void; null swallows, keeping observation non-fatal
  }

  on(name, fn, opts) {
    const list = this._hooks[name] || (this._hooks[name] = []);
    if (opts && opts.prepend) list.unshift(fn);
    else list.push(fn);

    return () => {
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    };
  }

  once(name, fn) {
    const off = this.on(name, (...args) => {
      off();
      return fn(...args);
    });
    return off;
  }

  // Every listener runs; a throw is caught so a broken observer cannot fault the producer. The
  // list is copied first so subscribe/unsubscribe during dispatch is safe.
  emit(name, ...args) {
    const list = this._hooks[name];
    if (!list) return;

    for (const fn of list.slice()) {
      try {
        fn(...args);
      } catch (e) {
        if (this.onError) this.onError(e, name);
      }
    }
  }

  // Run listeners until one claims the event (returns a non-nullish, non-false value); return
  // that value or undefined. Control-flow dispatch, so a throw propagates rather than hides.
  bail(name, ...args) {
    const list = this._hooks[name];
    if (!list) return undefined;

    for (const fn of list.slice()) {
      const r = fn(...args);
      if (r != null && r !== false) return r;
    }
    return undefined;
  }
}

// The app-wide bus. RootView.onEvent emits host events here (start, resize, key, mouse, tick,
// session, input_closed), so a plugin observes via events.on("start", …) without touching the router.
export const events = new Emitter();

// --- views --------------------------------------------------------------------------------
// A View owns a rectangle and a small override surface. Plugins subclass it or patch its prototype.
export class View {
  constructor() {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  get name() {
    return "view";
  }

  // Recompute layout against the current rect. Override for scrolling/animation state.
  update() {}

  // Paint into the current frame (between term.beginFrame/endFrame, handled by RootView).
  draw() {}

  // A key event the keymap did not consume. Return true if handled.
  onKey(_ev) {
    return false;
  }

  // A mouse event. Return true if handled.
  onMouse(_ev) {
    return false;
  }

  // Advance any animation state on a host tick.
  tick() {}

  // { periodMs } to request demand-driven ticks while this layer is painted, or null for idle.
  needsTick() {
    return null;
  }

  // Hardware-cursor request for this frame: { x, y, visible } or null (hidden). RootView
  // commits only the focused layer's cursor, so an overlay cannot leak the base's.
  cursor() {
    return null;
  }
}

// --- layout: the node tree ----------------------------------------------------------------
// The base layer is a binary tree of Nodes: a leaf holds a view, a split arranges two children as
// "row" (a|b) or "col" (a over b) with `ratio` the fraction given to `a`. RootView owns the tree.
export class Node {
  constructor(view) {
    this.type = "leaf";
    this.parent = null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.view = view || null;

    // Split-only, unused while a leaf.
    this.kind = null; // "row" | "col"
    this.a = null;
    this.b = null;
    this.ratio = 0.5;
  }

  // A fresh split of two nodes.
  static branch(kind, a, b, ratio) {
    const n = new Node(null);
    n.becomeSplit(kind, a, b, ratio);

    return n;
  }

  // Turn this node into a split of `a` and `b`, wiring their parent pointers. Splits a leaf in
  // place, keeping the node's identity in its own parent.
  becomeSplit(kind, a, b, ratio) {
    this.type = "split";
    this.kind = kind;
    this.view = null;
    this.ratio = ratio == null ? 0.5 : ratio;
    this.a = a;
    this.b = b;
    a.parent = this;
    b.parent = this;
  }

  // The leaves in left-to-right / top-to-bottom order.
  leaves(out) {
    out = out || [];
    if (this.type === "leaf") {
      out.push(this);
    } else {
      this.a.leaves(out);
      this.b.leaves(out);
    }

    return out;
  }

  // Assign rects top-down; a split reserves one cell for the divider between its children.
  layout(rect) {
    this.rect = rect;

    if (this.type === "leaf") {
      if (this.view) this.view.rect = rect;
      return;
    }

    if (this.kind === "row") {
      const total = Math.max(0, rect.w - 1);
      const aw = clampChildSize(Math.round(total * this.ratio), total);
      this.a.layout({ x: rect.x, y: rect.y, w: aw, h: rect.h });
      this.b.layout({ x: rect.x + aw + 1, y: rect.y, w: total - aw, h: rect.h });
    } else {
      const total = Math.max(0, rect.h - 1);
      const ah = clampChildSize(Math.round(total * this.ratio), total);
      this.a.layout({ x: rect.x, y: rect.y, w: rect.w, h: ah });
      this.b.layout({ x: rect.x, y: rect.y + ah + 1, w: rect.w, h: total - ah });
    }
  }

  // Paint the subtree; a split draws its divider between the children. `activeLeaf` is threaded so
  // a leaf's view can render its focused state.
  draw(activeLeaf) {
    if (this.type === "leaf") {
      const v = this.view;
      if (!v) return;

      if (v.update) v.update();
      v.draw(this === activeLeaf);
      return;
    }

    this.a.draw(activeLeaf);
    this.b.draw(activeLeaf);

    if (this.kind === "row") {
      const x = this.a.rect.x + this.a.rect.w;
      for (let y = this.rect.y; y < this.rect.y + this.rect.h; y++) text(x, y, "│", "YukeRule");
    } else if (this.rect.w > 0) {
      const y = this.a.rect.y + this.a.rect.h;
      text(this.rect.x, y, "─".repeat(this.rect.w), "YukeRule");
    }
  }
}

// Keep each child at least one cell when the space allows, so a divider never orphans a
// zero-width pane.
function clampChildSize(size, total) {
  if (total <= 1) return total;

  return Math.max(1, Math.min(size, total - 1));
}

// RootView owns the frame: a base node tree (tiled panes) under a z-ordered overlay stack. Paint
// is back-to-front; input front-to-back, a modal overlay (default) stopping it before the tree.
export class RootView {
  constructor() {
    this.root_node = null; // base layer: the tile tree
    this.activeLeaf = null; // the focused leaf
    this.overlays = []; // z-order; last === top === focused
    this.services = []; // background concerns (e.g. the daemon connection): tick + start, no paint
    this._started = false; // the start event has fired
  }

  // The focused leaf's view, or null. Named `active` so a command predicate can match the focused
  // view's name.
  get active() {
    return this.activeLeaf ? this.activeLeaf.view : null;
  }

  // Replace the base layer with `node`; focus its first leaf. Detaching its parent keeps the "root
  // has no parent" invariant, so close()'s root guard holds for a reused subtree.
  setRoot(node) {
    this.root_node = node;
    if (node) node.parent = null;
    this.activeLeaf = node ? node.leaves()[0] : null;
  }

  // Convenience: a single-leaf base holding `view`.
  setActive(view) {
    this.setRoot(view ? new Node(view) : null);
  }

  // Focus a leaf that is in the tree.
  focusLeaf(leaf) {
    if (leaf && this.root_node && this.root_node.leaves().indexOf(leaf) >= 0) this.activeLeaf = leaf;
  }

  // Split the active leaf in place: its view moves into the kept child and `view` into the new
  // leaf, which becomes active. Returns the new leaf.
  split(kind, view) {
    const leaf = this.activeLeaf;
    if (!leaf) return null;

    const add = new Node(view);
    leaf.becomeSplit(kind, new Node(leaf.view), add);
    this.activeLeaf = add;

    return add;
  }

  // Close the active leaf, absorbing its parent into the sibling in place. The lone root leaf has
  // no parent and cannot close. Focus moves into the absorbed subtree's first leaf.
  close() {
    const leaf = this.activeLeaf;
    const p = leaf && leaf.parent;
    if (!p) return;

    const sib = p.a === leaf ? p.b : p.a;
    p.type = sib.type;
    p.view = sib.view;
    p.kind = sib.kind;
    p.ratio = sib.ratio;
    p.a = sib.a;
    p.b = sib.b;
    if (p.a) p.a.parent = p;
    if (p.b) p.b.parent = p;

    this.activeLeaf = p.leaves()[0];
  }

  // Move focus to the nearest leaf in direction d ("h"|"j"|"k"|"l"), scoring by distance along
  // that axis plus a cross-axis penalty so aligned panes win.
  focusDir(d) {
    if (!this.activeLeaf) return;

    const cur = this.activeLeaf.rect;
    const cx = cur.x + cur.w / 2;
    const cy = cur.y + cur.h / 2;
    let best = null;
    let bestScore = Infinity;
    for (const leaf of this.root_node.leaves()) {
      if (leaf === this.activeLeaf) continue;

      const dx = leaf.rect.x + leaf.rect.w / 2 - cx;
      const dy = leaf.rect.y + leaf.rect.h / 2 - cy;
      const along = d === "h" ? -dx : d === "l" ? dx : d === "k" ? -dy : dy;
      if (along <= 0) continue;

      const cross = d === "h" || d === "l" ? Math.abs(dy) : Math.abs(dx);
      const score = along + cross * 2;
      if (score < bestScore) {
        bestScore = score;
        best = leaf;
      }
    }

    if (best) this.activeLeaf = best;
  }

  // Cycle focus through the leaves in tree order.
  focusCycle(step) {
    if (!this.root_node) return;

    const leaves = this.root_node.leaves();
    if (leaves.length === 0) return;

    let i = leaves.indexOf(this.activeLeaf);
    if (i < 0) i = 0;
    this.activeLeaf = leaves[(i + step + leaves.length) % leaves.length];
  }

  // Register a background service (optional onStart()/needsTick()/tick()). It never paints; it
  // rides the tick loop so a concern like the daemon connection runs under any view.
  addService(svc) {
    this.services.push(svc);
    if (this._started && svc.onStart) svc.onStart();
    this.syncTick();
    return svc;
  }

  // The layer that owns keyboard input and the cursor this frame.
  get focused() {
    return this.overlays.length ? this.overlays[this.overlays.length - 1] : this.active;
  }

  // Push a floating layer above the base (modal unless layer.modal === false). Returns it.
  pushOverlay(layer) {
    this.overlays.push(layer);
    this.draw();
    return layer;
  }

  // Remove `layer`, or the top one when omitted. No-op if absent.
  popOverlay(layer) {
    if (layer) {
      const i = this.overlays.indexOf(layer);
      if (i >= 0) this.overlays.splice(i, 1);
    } else {
      this.overlays.pop();
    }
    this.draw();
  }

  // Repaint outside the event path — e.g. from an async data continuation, which the host
  // does not otherwise redraw after.
  invalidate() {
    this.draw();
  }

  // Walk everything that can tick: every leaf view, overlays, and background services. Paint has
  // its own explicit walk in draw(); this one is for tick arming and advance only.
  _forEachTickable(fn) {
    if (this.root_node) for (const leaf of this.root_node.leaves()) if (leaf.view) fn(leaf.view);
    for (const layer of this.overlays) fn(layer);
    for (const svc of this.services) fn(svc);
  }

  draw() {
    if (!this.root_node && this.overlays.length === 0) return;

    term.beginFrame();

    if (this.root_node) {
      fill(0, 0, term.width, term.height, "Normal");
      this.root_node.layout({ x: 0, y: 0, w: term.width, h: term.height });
      this.root_node.draw(this.activeLeaf);
    }

    for (const layer of this.overlays) {
      if (layer.update) layer.update();
      layer.draw();
    }

    // One cursor, owned by the focused layer, so an overlay never leaks the base's.
    const f = this.focused;
    const c = f && f.cursor ? f.cursor() : null;
    if (c && c.visible) term.cursor(c.x, c.y, true);
    else term.cursor(0, 0, false);

    term.endFrame();
    this.syncTick();
  }

  // Arm host ticks while any painted layer is animating. Period is the fastest request so
  // a 100ms spinner under a slower overlay still advances on time.
  syncTick() {
    let period = null;
    this._forEachTickable((layer) => {
      if (!layer.needsTick) return;
      const t = layer.needsTick();
      if (!t) return;
      const ms = t.periodMs;
      period = period == null ? ms : Math.min(period, ms);
    });
    if (period != null) term.setNeedsTick(true, period);
    else term.setNeedsTick(false);
  }

  // Advance animation state on every layer that currently wants ticks.
  tickLayers() {
    this._forEachTickable((layer) => {
      if (!layer.needsTick || !layer.tick) return;
      if (layer.needsTick()) layer.tick();
    });
  }

  onEvent(ev) {
    // Observers see every host event first; consumption still runs through the router below.
    events.emit(ev.type, ev);

    if (ev.type === "input_closed") {
      term.setNeedsTick(false);
      term.quit();
      return;
    }

    if (ev.type === "start" || ev.type === "resize") {
      if (ev.type === "start" && !this._started) {
        this._started = true;
        for (const svc of this.services) if (svc.onStart) svc.onStart();
      }

      this.draw();
      return;
    }

    if (ev.type === "tick") {
      this.tickLayers();
      this.draw();
      return;
    }

    const top = this.overlays.length ? this.overlays[this.overlays.length - 1] : null;

    // The top overlay sees the event first; a modal one (the default) consumes it whether or
    // not it handled it, so nothing reaches the base. Always invokes the overlay's handler.
    const consumedByOverlay = (method) => {
      if (!top) return false;
      const handled = top[method](ev);
      return top.modal !== false || handled;
    };

    if (ev.type === "key") {
      // Releases are reported too; acting on both would run every shortcut twice.
      if (ev.event === "release") return;

      // The focused view gets first crack (so a text input can hold space, ":", "-"), except while
      // a chord is armed — the keymap must see the completion stroke. Unconsumed keys fall through.
      if (!consumedByOverlay("onKey")) {
        const viewTakes = !keymap.pending && this.active && this.active.onKey && this.active.onKey(ev);
        if (!viewTakes) keymap.onKey(ev);
      }
    } else if (ev.type === "mouse") {
      if (!consumedByOverlay("onMouse") && this.active) this.active.onMouse(ev);
    }

    this.draw();
  }
}

export const root = new RootView();

// Request process exit after the current event.
export function quit() {
  term.setNeedsTick(false);
  term.quit();
}

// The host calls globalThis.onEvent; route it through the root. Installed as a side effect of
// importing core, before the default UI (or a user file) registers views.
globalThis.onEvent = (ev) => root.onEvent(ev);
