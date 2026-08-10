// yuke:core — the client's editor core, imported by the bundled default UI and by the user's
// ~/.config/yuke/yuke.js. Every extension point is a method on a mutable exported object or a
// class prototype: ES imported bindings are read-only, so plugins extend by mutating these
// objects (command.perform = wrap(command.perform)) and prototypes (View.prototype.draw = …),
// never by reassigning an imported name.
import { term } from "yuke:term";

// --- config -------------------------------------------------------------------------------
// Plain mutable tunables. Plugins namespace their own settings under config.plugins.<name>;
// config.plugins.<name> === false is the convention for "disabled".
export const config = {
  plugins: Object.create(null),
};

// --- style: Neovim-like highlight groups over a palette -----------------------------------
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
    YukeSection: { fg: "muted", bold: true },
    YukeWorkspace: { fg: "muted" },
    YukeSession: { link: "Normal" },
    YukeSessionSel: { fg: "fg", bg: "sel" },
    YukeSessionMeta: { fg: "muted" },
    YukeSessionMetaSel: { fg: "muted", bg: "sel" },
    YukeSpinner: { fg: "accent" },
    YukeEmpty: { fg: "muted" },
    YukeShellTitle: { fg: "fg", bold: true },
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

// Largest cut at or before `at` that does not split a surrogate pair — splitting one yields
// invalid UTF-8, which the host rejects, dropping the whole write.
function cutBefore(s, at) {
  const c = s.charCodeAt(at - 1);
  return c >= 0xd800 && c <= 0xdbff ? at - 1 : at;
}

// Trim to `max` columns, counted in UTF-16 units — a wide or astral glyph still measures short,
// since the host exposes no cell width.
export function clip(s, max) {
  if (max <= 0) return "";
  s = String(s);
  if (s.length <= max) return s;
  if (max <= 1) return s.slice(0, cutBefore(s, max));

  return s.slice(0, cutBefore(s, max - 1)) + "…";
}

// --- commands -----------------------------------------------------------------------------
// A command is { predicate, perform }. The predicate answers "available now?" and may inject
// arguments: it returns a boolean, or an array [available, ...args] whose tail becomes the
// perform arguments. A string predicate is sugar for "the active view's name equals this".
export const command = {
  map: Object.create(null),

  add(predicate, map) {
    const pred = normalizePredicate(predicate);
    for (const name in map) {
      this.map[name] = { predicate: pred, perform: map[name] };
    }
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
// A stroke maps to an ordered list of command names / functions; on a key, the first entry
// whose predicate matches (or function returns !== false) wins. This ordered fallthrough is how
// one stroke means different things in different views. add() prepends so later (user) bindings
// take priority.
export const keymap = {
  map: Object.create(null),

  add(bindings, overwrite) {
    for (const stroke in bindings) {
      const key = normalizeStroke(stroke);
      const value = bindings[stroke];
      const list = Array.isArray(value) ? value.slice() : [value];
      if (overwrite || !this.map[key]) {
        this.map[key] = list;
      } else {
        this.map[key] = list.concat(this.map[key]);
      }
    }
  },

  // Try the bound commands for this key event; returns whether one handled it.
  onKey(ev) {
    const cmds = this.map[strokeOf(ev)];
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

// Modifier bit layout from the host (js.odin): Shift=1, Alt=2, Ctrl=4, Super=8.
const MOD_SHIFT = 1;
const MOD_ALT = 2;
const MOD_CTRL = 4;
const MOD_SUPER = 8;

// Canonical stroke for a key event: modifier names + the key token, "+"-joined and lowercased.
// The token is the case-folded character for a char key (stable across Kitty/legacy per
// js.odin) or the code name for a named key ("enter", "up", "f1"). Shift is dropped for
// char keys — the char is already folded and legacy terminals do not report Shift — but kept
// for named keys (so "shift+tab" works where the terminal reports it). Punctuation that needs
// exact shift state should bind a function that calls term.keyMatches.
// The one place the canonical stroke ordering lives: modifiers (ctrl, alt, super, shift) then
// the key token, "+"-joined. Both the event side (strokeOf) and the binding side
// (normalizeStroke) route through it so a bound stroke and its event can never disagree.
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

// --- views --------------------------------------------------------------------------------
// A View owns a rectangle and a small override surface. Plugins subclass it or patch its
// prototype. v1 hosts a single active view (no splits yet); term.width/height is the rect.
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

// RootView owns the frame, the base view, and a z-ordered overlay stack. Layers paint
// back-to-front (base first, overlays on top); input dispatches front-to-back (top overlay
// first). The top overlay is the focused layer; a modal one (the default) stops input from
// reaching the base. Ticks follow paint visibility (any layer that needsTick), so a base
// spinner keeps advancing under a floating window. Cursor stays focused-only.
export class RootView {
  constructor() {
    this.active = null; // base view
    this.overlays = []; // z-order; last === top === focused
  }

  setActive(view) {
    this.active = view;
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

  // Walk base + overlays (paint order). Used for tick arming and advance.
  _forEachLayer(fn) {
    if (this.active) fn(this.active);
    for (const layer of this.overlays) fn(layer);
  }

  draw() {
    if (!this.active && this.overlays.length === 0) return;

    term.beginFrame();

    if (this.active) {
      const r = this.active.rect;
      r.x = 0;
      r.y = 0;
      r.w = term.width;
      r.h = term.height;
      this.active.update();
      this.active.draw();
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
    this._forEachLayer((layer) => {
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
    this._forEachLayer((layer) => {
      if (!layer.needsTick || !layer.tick) return;
      if (layer.needsTick()) layer.tick();
    });
  }

  onEvent(ev) {
    if (ev.type === "input_closed") {
      term.setNeedsTick(false);
      term.quit();
      return;
    }

    if (ev.type === "start" || ev.type === "resize") {
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
      if (!consumedByOverlay("onKey") && !keymap.onKey(ev) && this.active) this.active.onKey(ev);
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
