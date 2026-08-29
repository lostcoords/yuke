import { term } from "yuke:term";

// --- config -------------------------------------------------------------------------------
// Runtime configuration. Direct daemon writes bypass validation.
export const config = {
  // Mouse reporting is always on. `scrollLines` is a screen-line count, so a wheel step moves the
  // same distance in a transcript and in a list.
  mouse: {
    scrollLines: 3,
    // A drag that ends copies the selection. A release is a deliberate end, so it never surprises.
    copyOnSelect: true,
  },
  daemon: {
    host: "127.0.0.1",
    port: 7880,
    autoConnect: true,
    retryMs: 5000,
    // Set a token for a protected daemon.
  },
};

// Merge a user config and return it for a default export.
export function defineConfig(partial) {
  if (partial == null || typeof partial !== "object" || Array.isArray(partial)) {
    throw new TypeError("defineConfig expects a config object");
  }
  for (const key of Object.keys(partial)) {
    if (key !== "daemon" && key !== "mouse") {
      throw new TypeError("defineConfig: unknown key " + key);
    }
  }
  const daemon = partial.daemon;
  const mouse = partial.mouse;
  if (daemon !== undefined) applyDaemonConfig(daemon);
  if (mouse !== undefined) applyMouseConfig(mouse);
  return partial;
}

const DAEMON_FIELDS = {
  host: (v) => (typeof v === "string" && v !== "") || "daemon.host must be a non-empty string",
  port: (v) => (Number.isInteger(v) && v >= 1 && v <= 65535) || "daemon.port must be an integer 1..65535",
  autoConnect: (v) => typeof v === "boolean" || "daemon.autoConnect must be a boolean",
  retryMs: (v) => (Number.isInteger(v) && v >= 1) || "daemon.retryMs must be a positive integer",
  token: (v) => typeof v === "string" || "daemon.token must be a string",
};

// Validate a daemon patch before it changes the config.
function applyDaemonConfig(d) {
  if (d == null || typeof d !== "object" || Array.isArray(d)) {
    throw new TypeError("defineConfig.daemon expects an object");
  }
  const patch = {};
  for (const key of Object.keys(d)) {
    if (!Object.prototype.hasOwnProperty.call(DAEMON_FIELDS, key)) {
      throw new TypeError("defineConfig.daemon: unknown key " + key);
    }
    const check = DAEMON_FIELDS[key];
    if (d[key] === undefined) continue;
    const ok = check(d[key]);
    if (ok !== true) throw new TypeError(ok);
    patch[key] = d[key];
  }
  Object.assign(config.daemon, patch);
}

const MOUSE_FIELDS = {
  copyOnSelect: (v) => typeof v === "boolean" || "mouse.copyOnSelect must be a boolean",
  scrollLines: (v) => (Number.isInteger(v) && v >= 1 && v <= 20) || "mouse.scrollLines must be an integer 1..20",
};

// Validate a mouse patch before it changes the config.
function applyMouseConfig(m) {
  if (m == null || typeof m !== "object" || Array.isArray(m)) {
    throw new TypeError("defineConfig.mouse expects an object");
  }
  const patch = {};
  for (const key of Object.keys(m)) {
    if (!Object.prototype.hasOwnProperty.call(MOUSE_FIELDS, key)) {
      throw new TypeError("defineConfig.mouse: unknown key " + key);
    }
    if (m[key] === undefined) continue;
    const ok = MOUSE_FIELDS[key](m[key]);
    if (ok !== true) throw new TypeError(ok);
    patch[key] = m[key];
  }
  Object.assign(config.mouse, patch);
}

// True for a wheel button. The wheel scrolls a pane but never moves the focus.
export function isWheel(button) {
  return button === "wheel_up" || button === "wheel_down" || button === "wheel_left" || button === "wheel_right";
}

// Bound a link chain the way neovim bounds `syn_ns_get_final_id`. A cycle falls back instead.
const link_depth_max = 100;

// The highlight groups use the palette. yuke is monochrome: emphasis is weight and inversion, not hue.
// `Normal` is `reset`, so the terminal background shows through. `danger` is the only color.
export const style = {
  palette: {
    fg: "reset",
    bg: "reset",
    danger: "red",
  },
  groups: {
    Normal: { fg: "fg", bg: "bg" },
    Comment: { fg: "fg", dim: true },
    YukeBrand: { fg: "fg", bold: true },
    YukeHeader: { link: "Comment" },
    YukeFooter: { link: "Comment" },
    YukeStatus: { fg: "fg", dim: true },
    YukeRule: { fg: "fg", dim: true },
    YukeSession: { link: "Normal" },
    YukeSessionSel: { reverse: true },
    YukeSessionMeta: { fg: "fg", dim: true },
    YukeSessionMetaSel: { reverse: true },
    YukeEmpty: { fg: "fg", dim: true },
    YukeHint: { fg: "fg", dim: true },
    YukeBar: { fg: "fg", dim: true },
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
      if (def.reverse) out.reverse = true;
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

// Limit `s` to `max` cells. Add an ellipsis when one cell remains and `ellipsis` is true.
export function clip(s, max, ellipsis = true) {
  if (max <= 0) return "";
  s = String(s);
  if (term.measure(s) <= max) return s;

  const ell = ellipsis && max > 1 ? 1 : 0;
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

// Wrap `s` in `width` cells and keep its UTF-16 offsets. A row holds [start, end) and a soft flag.
// `wrap` rebuilds its lines and drops the space runs, so editable text uses this function.
export function wrapOffsets(s, width) {
  s = String(s);
  if (width <= 0) return [{ start: 0, end: s.length, soft: false }];

  const rows = [];
  const gs = term.graphemes(s);
  let start = 0; // where the row starts
  let w = 0; // cells the row uses
  let breakAt = -1; // after the last space of the row
  let breakW = 0; // cells up to breakAt

  for (let k = 0; k < gs.length; k += 3) {
    const off = gs[k];
    const ch = s.slice(off, off + gs[k + 1]);
    if (ch === "\n") {
      rows.push({ start, end: off, soft: false });
      start = off + gs[k + 1];
      w = 0;
      breakAt = -1;
      continue;
    }

    // A space hangs past the right edge, so a wrap never starts a row with the space it broke on.
    // A row keeps one grapheme even when that grapheme is wider than the width.
    if (ch !== " " && w + gs[k + 2] > width && off > start) {
      if (breakAt > start) {
        rows.push({ start, end: breakAt, soft: true });
        w -= breakW;
        start = breakAt;
      } else {
        rows.push({ start, end: off, soft: true });
        w = 0;
        start = off;
      }
      breakAt = -1;
    }
    w += gs[k + 2];
    if (ch === " ") {
      breakAt = off + gs[k + 1];
      breakW = w;
    }
  }
  rows.push({ start, end: s.length, soft: false });
  return rows;
}

// Place `caret` in the rows of `wrapOffsets`. A caret on a soft break takes the next row, so the
// caret stays on the screen instead of one cell past the right edge.
export function caretRowCol(s, rows, caret) {
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (caret > r.end) continue;
    if (caret === r.end && r.soft && i + 1 < rows.length) continue;
    return { row: i, col: term.measure(s.slice(r.start, caret)) };
  }
  const last = rows[rows.length - 1];
  return { row: rows.length - 1, col: term.measure(s.slice(last.start, last.end)) };
}

// Return the caret index in `row` closest to the cell column `col`.
export function caretAtCol(s, row, col) {
  const line = s.slice(row.start, row.end);
  const gs = term.graphemes(line);
  let w = 0;
  for (let k = 0; k < gs.length; k += 3) {
    if (w + gs[k + 2] > col) return row.start + gs[k];
    w += gs[k + 2];
  }
  return row.end;
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

// The unnamed register. A yank or a delete fills it and `p` reads it. OSC 52 is write only, so a
// paste can never read the terminal's own clipboard.
export const register = {
  text: "",
  linewise: false,
  set(text, linewise) {
    this.text = String(text == null ? "" : text);
    this.linewise = !!linewise;
  },
};

// The key a modal layer reads. `strokeOf` folds a letter's case, so `G` needs the raw character.
// A chord keeps its stroke, so ctrl+d never reads as a letter.
export function modalKey(ev) {
  const m = ev.mods | 0;
  if (ev.code === "char" && ev.char && (m & (MOD_CTRL | MOD_ALT | MOD_SUPER)) === 0) {
    if (ev.char !== ev.char.toLowerCase() || (m & MOD_SHIFT) !== 0) return ev.char;
  }
  return strokeOf(ev);
}

// Return committed text. Use the folded key only for an unmodified legacy event.
export function textOf(ev) {
  if (ev.code === "paste") return ev.text || "";
  if (ev.code !== "char") return "";
  if (ev.text) return ev.text;
  if (((ev.mods | 0) & (MOD_CTRL | MOD_ALT | MOD_SUPER)) !== 0) return "";
  return ev.char || "";
}

export function isTextKey(ev) {
  return textOf(ev) !== "";
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

// A blank, a word character, or punctuation. A word motion stops where the class changes.
function graphemeClass(g) {
  if (!g || /\s/u.test(g)) return 0;
  return /[\p{L}\p{N}_]/u.test(g) ? 1 : 2;
}

// The graphemes of `s` with their offset and class, so a word motion never lands inside a cluster.
function graphemeCells(s) {
  const gs = term.graphemes(s);
  const out = [];
  for (let k = 0; k < gs.length; k += 3) out.push({ at: gs[k], cls: graphemeClass(s.slice(gs[k], gs[k] + gs[k + 1])) });
  return out;
}

function cellIndex(cells, at) {
  for (let i = 0; i < cells.length; i++) if (cells[i].at >= at) return i;
  return cells.length;
}

// The start of the next word, or the end of the text. This is vim's `w`.
export function nextWordStart(s, at) {
  const cells = graphemeCells(s);
  let i = cellIndex(cells, at);
  const cls = i < cells.length ? cells[i].cls : 0;
  while (i < cells.length && cells[i].cls === cls && cls !== 0) i++;
  while (i < cells.length && cells[i].cls === 0) i++;
  return i < cells.length ? cells[i].at : s.length;
}

// The start of the previous word, or the start of the text. This is vim's `b`.
export function prevWordStart(s, at) {
  const cells = graphemeCells(s);
  let i = cellIndex(cells, at) - 1;
  while (i >= 0 && cells[i].cls === 0) i--;
  if (i < 0) return 0;
  const cls = cells[i].cls;
  while (i > 0 && cells[i - 1].cls === cls) i--;
  return cells[i].at;
}

// The last grapheme of the word at or after the caret. This is vim's `e`, which lands on the char.
export function nextWordEnd(s, at) {
  const cells = graphemeCells(s);
  let i = cellIndex(cells, at) + 1;
  while (i < cells.length && cells[i].cls === 0) i++;
  if (i >= cells.length) return s.length;
  const cls = cells[i].cls;
  while (i + 1 < cells.length && cells[i + 1].cls === cls) i++;
  return cells[i].at;
}

// A caret step reads this many code units around the caret. No grapheme cluster is this long.
const grapheme_window = 256;

// A step needs only the grapheme beside the caret, so it scans a window and not the whole text.
// A cluster longer than the window is not real text.
export function prevGrapheme(s, at) {
  const from = Math.max(0, at - grapheme_window);
  const gs = term.graphemes(s.slice(from, at));
  let p = from;
  for (let k = 0; k < gs.length; k += 3) p = from + gs[k];
  return p;
}

export function nextGrapheme(s, at) {
  const to = Math.min(s.length, at + grapheme_window);
  const gs = term.graphemes(s.slice(at, to));
  if (gs.length === 0) return s.length;
  return at + gs[0] + gs[1];
}

export class TextInput {
  constructor(opts = {}) {
    this.text = "";
    this.caret = 0;
    this.onChange = opts.onChange || null;
    // onEdit(from, to, insertedLength) reports the range an edit replaced. An owner that keeps
    // offsets into the text uses this hook. TextInput never learns what those offsets mean.
    this.onEdit = opts.onEdit || null;
  }

  setText(s) {
    const had = this.text.length;
    this.text = String(s);
    this.caret = this.text.length;
    callHook(this, "onEdit", 0, had, this.text.length);
    callHook(this, "onChange");
  }

  beforeCaret() {
    return this.text.slice(0, this.caret);
  }

  _splice(from, to, ins) {
    this.text = this.text.slice(0, from) + ins + this.text.slice(to);
    this.caret = from + ins.length;
    callHook(this, "onEdit", from, to, ins.length);
    callHook(this, "onChange");
  }

  // Replace [from, to) with `s`. The caret lands after the new text.
  replace(from, to, s) {
    this._splice(from, to, String(s));
  }

  // Insert `s` at the caret with one edit. A paste and a newline key use this.
  insert(s) {
    s = String(s);
    if (s !== "") this._splice(this.caret, this.caret, s);
  }

  onKey(ev) {
    const s = strokeOf(ev);
    switch (s) {
      case "left":
        this.caret = prevGrapheme(this.text, this.caret);
        return true;
      case "right":
        this.caret = nextGrapheme(this.text, this.caret);
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
        const p = prevGrapheme(this.text, this.caret);
        if (p !== this.caret) this._splice(p, this.caret, "");
        return true;
      }
      case "delete": {
        const n = nextGrapheme(this.text, this.caret);
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
    const ins = textOf(ev);
    if (ins === "") return false;
    this.insert(ins);
    return true;
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
        // If `onError` throws, the remaining listeners still run.
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

  // Return the leaf that contains the cell. Return null outside this subtree.
  leafAt(col, row) {
    const r = this.rect;
    if (col < r.x || col >= r.x + r.w || row < r.y || row >= r.y + r.h) return null;
    if (this.type === "leaf") return this;
    return this.a.leafAt(col, row) || this.b.leafAt(col, row);
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

// --- status bar ---------------------------------------------------------------------------
// One row under the whole layout. A segment renders to a string, or to nothing when it has none to
// say, so a provider that is idle takes no space.
export const status = {
  _list: [],

  // Register a segment and return a disposer. `side` is "left" or "right"; `order` sorts a side.
  add(seg) {
    if (typeof seg.render !== "function") throw new TypeError("status.add needs a render function");
    const entry = { side: seg.side === "right" ? "right" : "left", order: seg.order || 0, render: seg.render };
    this._list.push(entry);
    this._list.sort((a, b) => a.order - b.order);
    return () => {
      const i = this._list.indexOf(entry);
      if (i >= 0) this._list.splice(i, 1);
    };
  },

  // The text of one side. A segment that renders nothing drops out of the join.
  side(which) {
    const out = [];
    for (const seg of this._list) {
      if (seg.side !== which) continue;
      const t = seg.render();
      if (t) out.push(String(t));
    }
    return out.join(" · ");
  },

  // The right side keeps the width it needs, so a long message never pushes it off the row.
  draw(rect) {
    const { x, y, w } = rect;
    if (w <= 0) return;
    fill(x, y, w, 1, "YukeBar");
    const right = this.side("right");
    const rw = right ? term.measure(right) : 0;
    if (right) text(x + Math.max(0, w - rw), y, clip(right, w), "YukeBar");
    const left = this.side("left");
    if (left) text(x, y, clip(left, Math.max(0, w - rw - 1)), "YukeBar");
  },
};

export class RootView {
  constructor() {
    this.root_node = null;
    this.activeLeaf = null;
    this.overlays = [];
    this.services = [];
    this._capture = null; // the leaf that owns the drag, from press to release
    this._needsDraw = false; // the host paints once after it drains the event queue
    this._started = false;
  }

  get active() {
    return this.activeLeaf ? this.activeLeaf.view : null;
  }

  setRoot(node) {
    if (node) node.parent = null;
    this.root_node = node;
    this.activeLeaf = node ? node.leaves()[0] : null;
    this._capture = null;
  }

  setActive(view) {
    this.setRoot(view == null ? null : new Node(view));
  }

  focusLeaf(leaf) {
    if (leaf && this.root_node && this.root_node.leaves().indexOf(leaf) >= 0) this.activeLeaf = leaf;
  }

  // Focus the leaf that holds `view`. Return false when the view is not in the tree.
  focusView(view) {
    if (!view || !this.root_node) return false;
    for (const leaf of this.root_node.leaves()) {
      if (leaf.view === view) {
        this.activeLeaf = leaf;
        return true;
      }
    }
    return false;
  }

  // Return the leaf that contains the cell. Return null over a split rule or outside the tree.
  leafAt(col, row) {
    return this.root_node ? this.root_node.leafAt(col, row) : null;
  }

  // Send the event to the leaf under the pointer. Focus a leaf on a button press, but not on a
  // wheel event. A left press captures the leaf, so a drag that leaves it still reaches the same
  // view and the release always arrives. Return true when a view consumed the event.
  routeMouse(ev) {
    if (this._capture && (ev.event === "drag" || ev.event === "release")) {
      const held = this._capture;
      if (ev.event === "release") this._capture = null;
      const live = this.root_node && this.root_node.leaves().indexOf(held) >= 0;
      return live && held.view ? !!callHook(held.view, "onMouse", ev) : false;
    }
    const leaf = this.leafAt(ev.col, ev.row);
    if (!leaf || !leaf.view) return false;
    if (ev.event === "press" && !isWheel(ev.button)) {
      this.focusLeaf(leaf);
      if (ev.button === "left") this._capture = leaf;
    }
    return !!callHook(leaf.view, "onMouse", ev);
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
    this.invalidate();
    return layer;
  }

  popOverlay(layer) {
    if (layer) {
      const i = this.overlays.indexOf(layer);
      if (i >= 0) this.overlays.splice(i, 1);
    } else this.overlays.pop();
    this.invalidate();
  }

  // Ask for a frame. The host paints once after the queue drains, so a burst costs one paint.
  invalidate() {
    this._needsDraw = true;
  }

  // Paint if anything asked for it. The host calls this after it drains the event queue.
  flush() {
    if (!this._needsDraw) return;
    this._needsDraw = false;
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
    // The bar owns the last row, so every pane rect below derives from the shorter height.
    const barY = term.height - 1;
    if (this.root_node) {
      fill(0, 0, term.width, term.height, "Normal");
      this.root_node.layout({ x: 0, y: 0, w: term.width, h: Math.max(0, barY) });
      this.root_node.draw(this.activeLeaf);
    }
    if (barY >= 0) status.draw({ x: 0, y: barY, w: term.width, h: 1 });
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
      this.invalidate();
      return;
    }
    if (ev.type === "tick") {
      this.tickLayers();
      this.invalidate();
      return;
    }
    // Redraw on focus gain. A focus loss changes no view state.
    if (ev.type === "focus") {
      if (ev.focused) this.invalidate();
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
      if (!consumedByOverlay("onMouse")) this.routeMouse(ev);
    }
    this.invalidate();
  }
}

export const root = new RootView();

export function quit() {
  term.setNeedsTick(false);
  term.quit();
}

// A bare key never quits. A stray key in a modal layer must not end the session.
command.add(null, { quit });

globalThis.onEvent = (ev) => root.onEvent(ev);
globalThis.flushFrame = () => root.flush();
