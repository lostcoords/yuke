import { term } from "yuke:term";

// Bound a link chain the way neovim bounds `syn_ns_get_final_id`. A cycle falls back instead.
const link_depth_max = 100;

// Define highlight groups over the palette. Call `invalidate()` after changes.
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
    YukeSession: { link: "Normal" },
    YukeSessionSel: { fg: "fg", bg: "sel" },
    YukeSessionMeta: { fg: "muted" },
    YukeSessionMetaSel: { fg: "muted", bg: "sel" },
    YukeEmpty: { fg: "muted" },
    YukeHint: { fg: "muted" },
  },
  _cache: Object.create(null),
  resolve(name) {
    const cached = this._cache[name];
    if (cached) return cached;

    let def = this.groups[name];
    for (let i = 0; def && def.link && i < link_depth_max; i++) def = this.groups[def.link];
    if (def && def.link) def = null;

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

export function fill(x, y, w, h, group) {
  term.fill(x, y, w, h, style.resolve(group));
}

export function text(x, y, s, group) {
  term.text(x, y, s, style.resolve(group));
}

// Limit `s` to `max` cells. Add an ellipsis when one cell remains.
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

// Wrap `s` to `width` cells. A newline breaks the line. A word wider than `width` breaks by grapheme.
// A grapheme wider than `width` keeps its own line. That line is wider than `width`.
export function wrap(s, width) {
  s = String(s);
  if (width <= 0) return [""];

  const lines = [];
  for (const para of s.split("\n")) wrapParagraph(para, width, lines);
  return lines;
}

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

function hardBreak(s, width) {
  const gs = term.graphemes(s);
  const pieces = [];
  let piece = "";
  let w = 0;
  for (let k = 0; k < gs.length; k += 3) {
    if (w + gs[k + 2] > width && piece !== "") {
      pieces.push({ text: piece, w });
      piece = "";
      w = 0;
    }
    piece += s.slice(gs[k], gs[k] + gs[k + 1]);
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

// A command has a predicate and an action. A string predicate matches the active view.
export const command = {
  map: Object.create(null),

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

// New bindings run before old bindings. A space separates chord strokes.
export const keymap = {
  map: Object.create(null),
  prefixes: Object.create(null),
  pending: null,

  add(bindings, overwrite) {
    const added = [];
    for (const seq in bindings) {
      const key = normalizeSeq(seq);
      const value = bindings[seq];
      const list = Array.isArray(value) ? value.slice() : [value];
      if (overwrite || !this.map[key]) this.map[key] = list;
      else this.map[key] = list.concat(this.map[key]);
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

  _rebuildPrefixes() {
    this.prefixes = Object.create(null);
    for (const key in this.map) {
      const sp = key.indexOf(" ");
      if (sp > 0) this.prefixes[key.slice(0, sp)] = true;
    }
    if (this.pending && !this.prefixes[this.pending]) this.pending = null;
  },

  onKey(ev) {
    const s = strokeOf(ev);
    if (!s) return false;
    if (this.pending) {
      const prefix = this.pending;
      this.pending = null;
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

function normalizeSeq(seq) {
  const s = String(seq);
  if (s.trim() === "") return normalizeStroke(s);
  return s.trim().split(/\s+/).map(normalizeStroke).join(" ");
}

function stripCtrl(stroke) {
  return stroke.indexOf("ctrl+") === 0 ? stroke.slice(5) : stroke;
}

const MOD_SHIFT = 1;
const MOD_ALT = 2;
const MOD_CTRL = 4;
const MOD_SUPER = 8;

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
  return joinStroke(
    { ctrl: !!(m & MOD_CTRL), alt: !!(m & MOD_ALT), super: !!(m & MOD_SUPER), shift },
    token,
  );
}

export function isTextKey(ev) {
  return ev.code === "char" && !!ev.char && ((ev.mods | 0) & ~MOD_SHIFT) === 0;
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

// A layer implements only the hooks it needs.
function callHook(obj, name, ...args) {
  const fn = obj && obj[name];
  // `Reflect.apply` keeps the receiver even when the hook shadows `Function.prototype.apply`.
  return typeof fn === "function" ? Reflect.apply(fn, obj, args) : undefined;
}

// `draw` runs every frame. A layer or a view without `draw` never appears.
function requireDraw(obj, message) {
  if (!obj || typeof obj.draw !== "function") throw new TypeError(message);
}

function deleteWordBack(s, caret) {
  let i = caret;
  while (i > 0 && s[i - 1] === " ") i--;
  while (i > 0 && s[i - 1] !== " ") i--;
  return i;
}

export class TextInput {
  constructor(opts = {}) {
    this.text = "";
    this.caret = 0;
    this.onChange = opts.onChange || null;
  }

  setText(s) {
    this.text = String(s);
    this.caret = this.text.length;
  }

  beforeCaret() {
    return this.text.slice(0, this.caret);
  }

  _prev(caret) {
    const gs = term.graphemes(this.text);
    let p = 0;
    for (let k = 0; k < gs.length; k += 3) {
      if (gs[k] >= caret) break;
      p = gs[k];
    }
    return p;
  }

  _next(caret) {
    const gs = term.graphemes(this.text);
    for (let k = 0; k < gs.length; k += 3) {
      const end = gs[k] + gs[k + 1];
      if (end > caret) return end;
    }
    return this.text.length;
  }

  _splice(from, to, ins) {
    this.text = this.text.slice(0, from) + ins + this.text.slice(to);
    this.caret = from + ins.length;
    callHook(this, "onChange");
  }

  onKey(ev) {
    const s = strokeOf(ev);
    switch (s) {
      case "left":
        this.caret = this._prev(this.caret);
        return true;
      case "right":
        this.caret = this._next(this.caret);
        return true;
      case "home":
      case "ctrl+a":
        this.caret = 0;
        return true;
      case "end":
      case "ctrl+e":
        this.caret = this.text.length;
        return true;
      case "backspace": {
        const p = this._prev(this.caret);
        if (p !== this.caret) this._splice(p, this.caret, "");
        return true;
      }
      case "delete": {
        const n = this._next(this.caret);
        if (n !== this.caret) this._splice(this.caret, n, "");
        return true;
      }
      case "ctrl+w": {
        const p = deleteWordBack(this.text, this.caret);
        if (p !== this.caret) this._splice(p, this.caret, "");
        return true;
      }
      case "ctrl+u":
        if (this.caret > 0) this._splice(0, this.caret, "");
        return true;
    }
    if (isTextKey(ev)) {
      this._splice(this.caret, this.caret, ev.char);
      return true;
    }
    return false;
  }
}

export function caretCol(w, prompt, before) {
  return Math.min(w - 1, term.measure(prompt + before));
}

export class Emitter {
  constructor() {
    this._hooks = Object.create(null);
    this.onError = null;
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

  emit(name, ...args) {
    const list = this._hooks[name];
    if (!list) return;
    for (const fn of list.slice()) {
      try {
        fn(...args);
      } catch (e) {
        // A throwing `onError` must not stop the listeners that remain.
        try {
          callHook(this, "onError", e, name);
        } catch (_ignored) {}
      }
    }
  }

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

export const events = new Emitter();

export class View {
  constructor() {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }
  get name() {
    return "view";
  }
  update() {}
  draw() {}
  onKey(_ev) {
    return false;
  }
  onMouse(_ev) {
    return false;
  }
  tick() {}
  needsTick() {
    return null;
  }
  cursor() {
    return null;
  }
}

export class Node {
  constructor(view) {
    if (view != null) requireDraw(view, "a view needs a draw method");
    this.type = "leaf";
    this.parent = null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.view = view || null;
    this.kind = null;
    this.a = null;
    this.b = null;
    this.ratio = 0.5;
  }

  static branch(kind, a, b, ratio) {
    const n = new Node(null);
    n.becomeSplit(kind, a, b, ratio);
    return n;
  }

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

  leaves(out) {
    out = out || [];
    if (this.type === "leaf") out.push(this);
    else {
      this.a.leaves(out);
      this.b.leaves(out);
    }
    return out;
  }

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

  draw(activeLeaf) {
    if (this.type === "leaf") {
      const v = this.view;
      if (!v) return;
      callHook(v, "update");
      callHook(v, "draw", this === activeLeaf);
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

function clampChildSize(size, total) {
  if (total <= 1) return total;
  return Math.max(1, Math.min(size, total - 1));
}

export class RootView {
  constructor() {
    this.root_node = null;
    this.activeLeaf = null;
    this.overlays = [];
    this.services = [];
    this._started = false;
  }

  get active() {
    return this.activeLeaf ? this.activeLeaf.view : null;
  }

  setRoot(node) {
    if (node) node.parent = null;
    this.root_node = node;
    this.activeLeaf = node ? node.leaves()[0] : null;
  }

  setActive(view) {
    this.setRoot(view == null ? null : new Node(view));
  }

  focusLeaf(leaf) {
    if (leaf && this.root_node && this.root_node.leaves().indexOf(leaf) >= 0) this.activeLeaf = leaf;
  }

  split(kind, view) {
    const leaf = this.activeLeaf;
    if (!leaf) return null;
    const add = new Node(view);
    leaf.becomeSplit(kind, new Node(leaf.view), add);
    this.activeLeaf = add;
    return add;
  }

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

  focusCycle(step) {
    if (!this.root_node) return;
    const leaves = this.root_node.leaves();
    if (leaves.length === 0) return;
    let i = leaves.indexOf(this.activeLeaf);
    if (i < 0) i = 0;
    this.activeLeaf = leaves[(i + step + leaves.length) % leaves.length];
  }

  addService(svc) {
    this.services.push(svc);
    if (this._started) callHook(svc, "onStart");
    this.syncTick();
    return svc;
  }

  get focused() {
    return this.overlays.length ? this.overlays[this.overlays.length - 1] : this.active;
  }

  pushOverlay(layer) {
    requireDraw(layer, "pushOverlay needs a layer with a draw method");
    this.overlays.push(layer);
    this.draw();
    return layer;
  }

  popOverlay(layer) {
    if (layer) {
      const i = this.overlays.indexOf(layer);
      if (i >= 0) this.overlays.splice(i, 1);
    } else this.overlays.pop();
    this.draw();
  }

  invalidate() {
    this.draw();
  }

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
      callHook(layer, "update");
      callHook(layer, "draw");
    }
    const c = callHook(this.focused, "cursor");
    if (c && c.visible) term.cursor(c.x, c.y, true);
    else term.cursor(0, 0, false);
    term.endFrame();
    this.syncTick();
  }

  syncTick() {
    let period = null;
    this._forEachTickable((layer) => {
      const t = callHook(layer, "needsTick");
      if (!t) return;
      const ms = t.periodMs;
      period = period == null ? ms : Math.min(period, ms);
    });
    if (period != null) term.setNeedsTick(true, period);
    else term.setNeedsTick(false);
  }

  tickLayers() {
    this._forEachTickable((layer) => {
      if (callHook(layer, "needsTick")) callHook(layer, "tick");
    });
  }

  onEvent(ev) {
    events.emit(ev.type, ev);
    if (ev.type === "input_closed") {
      term.setNeedsTick(false);
      term.quit();
      return;
    }
    if (ev.type === "start" || ev.type === "resize") {
      if (ev.type === "start" && !this._started) {
        this._started = true;
        for (const svc of this.services) callHook(svc, "onStart");
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
    // A modal overlay consumes the event even when the overlay has no requested hook.
    const consumedByOverlay = (method) => {
      if (!top) return false;
      const handled = callHook(top, method, ev);
      return top.modal !== false || !!handled;
    };
    if (ev.type === "key") {
      if (ev.event === "release") return;
      if (!consumedByOverlay("onKey")) {
        const viewTakes = !keymap.pending && callHook(this.active, "onKey", ev);
        if (!viewTakes) keymap.onKey(ev);
      }
    } else if (ev.type === "mouse") {
      if (!consumedByOverlay("onMouse")) callHook(this.active, "onMouse", ev);
    }
    this.draw();
  }
}

export const root = new RootView();

export function quit() {
  term.setNeedsTick(false);
  term.quit();
}

command.add(null, { quit });
keymap.add({ q: "quit" });

globalThis.onEvent = (ev) => root.onEvent(ev);
