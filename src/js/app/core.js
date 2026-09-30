import { clip } from "yuke:internal/text-input";
import { normalizeSeq, stripCtrl, strokeOf } from "yuke:internal/keys";
import { term } from "yuke:internal/native/term";
import { callHook, config, events, fault, notify, once } from "yuke:internal/kernel";

/** @import { Color, Style } from "yuke:internal/native/term" */
/** @import { CommandAction, CommandEntry, CommandListing, CommandRegistry, CommandSpec, ContextExpr, ContextFlag, ContextNode, KeyBinding, KeyEntry, KeymapRegistry, NavTarget, NodeShape, Overlay, Pending, Rect, RootEvent, RouteEntry, RouteWhere, StatusEntry, StatusSegment, StyleConfig, StyleGroup, StyleLayer, Tickable, TickableEntry, ViewLike } from "./types/core.js" */

/**
 * True for a wheel button of a mouse event. The wheel scrolls a pane but never moves the focus.
 * @param {string} button
 * @returns {boolean}
 */
export function isWheel(button) {
  return button === "wheel_up" || button === "wheel_down" || button === "wheel_left" || button === "wheel_right";
}

/**
 * True when the cell at `col`, `row` is inside `r`.
 * @param {Rect} r
 * @param {number} col
 * @param {number} row
 * @returns {boolean}
 */
export const contains = (r, col, row) => col >= r.x && col < r.x + r.w && row >= r.y && row < r.y + r.h;

// Bound a link chain, so a cycle falls back instead of looping for ever.
const link_depth_max = 100;

/** @type {Record<string, Color>} */
const CORE_PALETTE = { fg: "reset", bg: "reset", danger: "red" };
const style_fg = 1 << 0;
const style_bg = 1 << 1;
const style_ul = 1 << 2;
const style_bold = 1 << 3;
const style_dim = 1 << 4;
const style_italic = 1 << 5;
const style_reverse = 1 << 6;
const style_underline = 1 << 7;
const internal_style_prefix = "\x00";
// A style change drops the field masks and every composed pair.
/** @type {Record<string, number>} */
let styleMasks = Object.create(null);
/** @type {Record<string, Record<string, Style>>} */
let rowStyles = Object.create(null);
/** @type {Record<string, Record<string, string>>} */
let overlayGroups = Object.create(null);
/** Overlay groups whose explicit background wins over a row background. @type {Set<string>} */
let topBgGroups = new Set();
let overlayGroupId = 0;

/**
 * The highlight groups and the palette. A group merges its default (from `set` with `{ default: true }`), then the active theme, then each other `set` in call order.
 * The core groups are monochrome: emphasis is weight and inversion, `Normal` is `reset`, and `danger` is the only color.
 * @type {StyleConfig}
 */
export const style = {
  palette: { ...CORE_PALETTE },
  groups: Object.create(null),
  // A Map, because a dictionary object that grows in step with `groups` shares its shape, and each add then copies the shape.
  _base: new Map(),
  // Slot 0 holds the theme, or an empty layer, so the theme merges before every other change.
  _patches: [{}],
  _cache: Object.create(null),

  set(groups, options) {
    for (const name in groups) if (name.startsWith(internal_style_prefix)) throw new TypeError("style.set: a NUL-prefixed name is reserved");
    if (!options?.default) return this._layer({ groups });
    // A default is the base of a group, so a second default for one name is a conflict and not a silent loss.
    for (const name in groups) if (this._base.has(name)) throw new TypeError("style.set: " + name + " has a default; change it without { default: true }");
    for (const name in groups) {
      this._base.set(name, /** @type {StyleGroup} */ (groups[name]));
      this._group(name);
    }
    this._changed();
    return once(() => {
      // A key added to `groups` after the call names no default of this call, so it stays.
      for (const name in groups) if (this._base.get(name) === groups[name]) this._base.delete(name);
      this._apply({ groups });
    });
  },

  setPalette(colors) {
    return this._layer({ palette: colors });
  },

  theme(theme) {
    // A fresh layer per call, so the disposer of an earlier call with the same object cannot remove this one.
    const layer = { ...theme };
    const previous = /** @type {StyleLayer} */ (this._patches[0]);
    this._patches[0] = layer;
    this._apply(previous);
    this._apply(layer);
    return once(() => {
      if (this._patches[0] !== layer) return;
      this._patches[0] = {};
      this._apply(layer);
    });
  },

  /** @param {StyleLayer} layer @returns {() => void} */
  _layer(layer) {
    this._patches.push(layer);
    this._apply(layer);
    return once(() => {
      const at = this._patches.indexOf(layer);
      // `once` runs this one time, and only this disposer removes the layer.
      if (at < 1) throw new Error("style: the layer is gone");
      this._patches.splice(at, 1);
      this._apply(layer);
    });
  },

  // Merge again what one layer touches, then drop every cached style and repaint.
  /** @param {StyleLayer} layer */
  _apply(layer) {
    if (layer.palette) {
      const palette = { ...CORE_PALETTE };
      for (const each of this._patches) if (each.palette) patch(palette, each.palette);
      this.palette = /** @type {Record<string, Color>} */ (palette);
    }
    if (layer.groups) for (const name in layer.groups) this._group(name);
    this._changed();
  },

  // Merge one group. An unchanged group shares its base object, so the merged view costs nothing until a change.
  /** @param {string} name */
  _group(name) {
    const base = this._base.get(name);
    /** @type {StyleGroup | undefined} */
    let out = base;
    const patches = this._patches;
    for (let i = 0; i < patches.length; i++) {
      const change = /** @type {StyleLayer} */ (patches[i]).groups?.[name];
      if (change === undefined) continue;
      if (out === base) out = { ...base };
      patch(/** @type {StyleGroup} */ (out), change);
    }
    if (out) this.groups[name] = out;
    else delete this.groups[name];
  },

  _changed() {
    this._cache = Object.create(null);
    styleMasks = Object.create(null);
    rowStyles = Object.create(null);
    overlayGroups = Object.create(null);
    topBgGroups = new Set();
    overlayGroupId = 0;
    root.invalidatePaint();
  },

  // A hit reads only the cache: QuickJS sets up every local of a function on each call, so the locals of a miss live in `_build`.
  resolve(name) {
    return this._cache[name] || this._build(name);
  },

  /** @param {string} name @returns {Style} */
  _build(name) {
    // A group's own fields win over the fields of the group it links to, and a link cycle gives the default style; locals keep a cache miss to one allocation.
    let fg, bg, ul, bold, dim, italic, reverse, underline;
    let def = this.groups[name];
    for (let depth = 0; def; depth++) {
      if (depth === link_depth_max) {
        fg = bg = ul = bold = dim = italic = reverse = underline = undefined;
        break;
      }
      fg ??= def.fg;
      bg ??= def.bg;
      ul ??= def.ul;
      bold ??= def.bold;
      dim ??= def.dim;
      italic ??= def.italic;
      reverse ??= def.reverse;
      underline ??= def.underline;
      def = def.link === undefined ? undefined : this.groups[def.link];
    }

    let mask = 0;
    if (fg !== undefined) mask |= style_fg;
    if (bg !== undefined) mask |= style_bg;
    if (ul !== undefined) mask |= style_ul;
    if (bold !== undefined) mask |= style_bold;
    if (dim !== undefined) mask |= style_dim;
    if (italic !== undefined) mask |= style_italic;
    if (reverse !== undefined) mask |= style_reverse;
    if (underline !== undefined) mask |= style_underline;

    /** @type {Style} */
    const out = {};
    if (bg !== undefined) out.bg = resolveColor(this.palette, bg);
    if (ul !== undefined) out.ul = resolveColor(this.palette, ul);
    if (bold) out.bold = true;
    if (dim) out.dim = true;
    if (italic) out.italic = true;
    if (underline) out.underline = true;
    if (reverse) out.reverse = true;
    out.fg = resolveColor(this.palette, fg ?? "fg");

    styleMasks[name] = mask;
    this._cache[name] = out;
    return out;
  },
};

/**
 * Resolve a text group over a row group. The text's explicit fields win. The row's explicit background wins unless a top overlay explicitly sets it.
 * The cache owns the returned composite until any style change.
 * @param {string} name
 * @param {string} baseGroup
 * @returns {Style}
 */
export function resolveRowStyle(name, baseGroup) {
  return rowStyles[baseGroup]?.[name] || buildRowStyle(name, baseGroup);
}

/** @param {string} name @param {string} baseGroup @returns {Style} */
function buildRowStyle(name, baseGroup) {
  const byName = rowStyles[baseGroup] || (rowStyles[baseGroup] = Object.create(null));
  const base = style.resolve(baseGroup);
  const out = { ...base };
  applyStyle(out, style.resolve(name), maskOf(name));
  if ((maskOf(baseGroup) & style_bg) && !topBgGroups.has(name)) out.bg = /** @type {Color} */ (base.bg);
  byName[name] = out;
  return out;
}

/**
 * Return the cached internal group that applies the explicit fields of `overlay` over `name`.
 * Its explicit overlay fields stay above a later row composition. The cache owns the returned name and style until any style change.
 * @param {string} name
 * @param {string} overlay
 * @returns {string}
 */
export function overlayStyleGroup(name, overlay) {
  return overlayGroups[overlay]?.[name] || buildOverlayStyleGroup(name, overlay);
}

/** @param {string} name @param {string} overlay @returns {string} */
function buildOverlayStyleGroup(name, overlay) {
  const byName = overlayGroups[overlay] || (overlayGroups[overlay] = Object.create(null));
  const overlayMask = maskOf(overlay);
  if (overlayMask === 0) {
    byName[name] = name;
    return name;
  }
  const composite = internal_style_prefix + overlayGroupId++;
  const out = { ...style.resolve(name) };
  applyStyle(out, style.resolve(overlay), overlayMask);
  styleMasks[composite] = maskOf(name) | overlayMask;
  if ((overlayMask & style_bg) !== 0 || topBgGroups.has(name)) topBgGroups.add(composite);
  style._cache[composite] = out;
  byName[name] = composite;
  return composite;
}

/** @param {string} name @returns {number} */
function maskOf(name) {
  style.resolve(name);
  return styleMasks[name] || 0;
}

/** @param {Style} out @param {Style} change @param {number} mask */
function applyStyle(out, change, mask) {
  if (mask & style_fg) out.fg = /** @type {Color} */ (change.fg);
  if (mask & style_bg) out.bg = /** @type {Color} */ (change.bg);
  if (mask & style_ul) out.ul = /** @type {Color} */ (change.ul);
  if (mask & style_bold) setFlag(out, "bold", change.bold === true);
  if (mask & style_dim) setFlag(out, "dim", change.dim === true);
  if (mask & style_italic) setFlag(out, "italic", change.italic === true);
  if (mask & style_reverse) setFlag(out, "reverse", change.reverse === true);
  if (mask & style_underline) setFlag(out, "underline", change.underline === true);
}

/** @param {Style} out @param {"bold" | "dim" | "italic" | "reverse" | "underline"} field @param {boolean} on */
function setFlag(out, field, on) {
  if (on) out[field] = true;
  else delete out[field];
}

// Apply one patch in place: a null field deletes the field.
/** @param {object} out @param {object} change @returns {void} */
function patch(out, change) {
  const into = /** @type {Record<string, unknown>} */ (out);
  const from = /** @type {Record<string, unknown>} */ (change);
  for (const key in from) {
    if (from[key] === null) delete into[key];
    else into[key] = from[key];
  }
}

/** @param {Record<string, Color>} palette @param {Color | string} color @returns {Color} */
function resolveColor(palette, color) {
  if (typeof color === "string" && Object.hasOwn(palette, color) && palette[color] !== undefined) return palette[color];
  return /** @type {Color} */ (color);
}

/**
 * Paint a rectangle of screen cells with the style of the highlight group `group`. A view calls it from its `draw`.
 * @param {number} x
 * @param {number} y
 * @param {number} w
 * @param {number} h
 * @param {string} group
 * @returns {void}
 */
export function fill(x, y, w, h, group) {
  term.fill(x, y, w, h, style.resolve(group));
}

/**
 * Draw `s` from the screen cell at `x`, `y` with the style of the highlight group `group`. A view calls it from its `draw`.
 * @param {number} x
 * @param {number} y
 * @param {string} s
 * @param {string} group
 * @returns {void}
 */
export function text(x, y, s, group) {
  term.text(x, y, s, style.resolve(group));
}

/**
 * The command registry. A command has a predicate and an action. A key binding, not the command, names the context where it applies.
 * @type {CommandRegistry}
 */
export const command = {
  map: Object.create(null),

  // Register one command; a later registration of the name shadows an earlier one. `desc` lists it as a user action.
  /** @param {string} name @param {CommandSpec} spec @returns {() => void} */
  add(name, spec) {
    // A command comes from plugin code, so its shape is checked here.
    if (typeof name !== "string" || name === "") throw new TypeError("a command needs a name");
    if (typeof spec?.run !== "function") throw new TypeError("command " + name + " needs a run function");
    if (spec.when != null && typeof spec.when !== "function") throw new TypeError("command " + name + ": `when` must be a function");
    // The slash menu lists only described commands, so a slash word without `desc` would never answer.
    if (spec.slash && !spec.desc) throw new TypeError("command " + name + ": a slash word needs `desc`");
    // `slash: true` takes the name after the owner prefix, so "session:interrupt" answers "/interrupt".
    const slash = spec.slash === true ? name.slice(name.lastIndexOf(":") + 1) : spec.slash || null;
    /** @type {CommandEntry} */
    const entry = { when: spec.when ?? null, run: spec.run, desc: spec.desc ?? null, slash, args: spec.args === true, aboveModal: spec.aboveModal === true };
    const list = this.map[name] || (this.map[name] = []);
    list.unshift(entry);
    // The removal finds the entry by identity, so a second call finds nothing and does nothing.
    return () => {
      const held = this.map[name];
      if (!held) return;
      const i = held.indexOf(entry);
      if (i >= 0) held.splice(i, 1);
      if (held.length === 0) delete this.map[name];
    };
  },

  // A rejected predicate lets the next entry run.
  perform(name, ...args) {
    for (const entry of this.map[name] || []) {
      const call = evalPredicate(entry, args);
      if (call === null) continue;
      entry.run(...call);
      return true;
    }
    return false;
  },

  // Run the entry that `perform` would run, but only when that entry is marked `aboveModal`.
  /** @param {string} name @param {...any} args @returns {boolean} */
  performAboveModal(name, ...args) {
    for (const entry of this.map[name] || []) {
      const call = evalPredicate(entry, args);
      if (call === null) continue;
      if (!entry.aboveModal) return false;
      entry.run(...call);
      return true;
    }
    return false;
  },

  // A throwing predicate counts as available, so one bad predicate never empties a listing.
  available(name) {
    return isAvailable(this.map[name]);
  },

  // List the available commands that have a description, in palette order. A keymap target has none, so no palette lists it.
  list() {
    /** @type {CommandListing[]} */
    const out = [];
    for (const name in this.map) {
      const list = /** @type {CommandEntry[]} */ (this.map[name]);
      // The newest description wins, so a plain shadow keeps the listing under it.
      const listed = list.find((entry) => entry.desc);
      if (listed && isAvailable(list)) out.push({ name, desc: /** @type {string} */ (listed.desc), slash: listed.slash, args: listed.args });
    }
    return out.sort(byWord);
  },
};

// Sort by the word the palette shows, "/" + slash or the name, in code-unit order without building it: localeCompare traps in QuickJS.
/** @param {CommandListing} a @param {CommandListing} b @returns {number} */
function byWord(a, b) {
  let x = a.slash ?? a.name, y = b.slash ?? b.name;
  if ((a.slash === null) !== (b.slash === null)) {
    // Against "/" + slash, a bare name's first character decides; a name that starts with "/" compares its rest.
    const c = (a.slash === null ? x : y).charCodeAt(0);
    if (c !== 47) return (c > 47) === (a.slash !== null) ? -1 : 1;
    if (a.slash === null) x = x.slice(1); else y = y.slice(1);
  }
  return x < y ? -1 : x > y ? 1 : 0;
}


// Report whether an entry would run, without the allocation a selection needs.
/** @param {CommandEntry[] | undefined} list @returns {boolean} */
function isAvailable(list) {
  if (!list) return false;
  for (const entry of list) {
    try {
      if (evalPredicate(entry, []) !== null) return true;
    } catch (_e) {
      return true;
    }
  }
  return false;
}

// Evaluate one predicate and return the arguments to run with, or null when it rejects.
/** @param {CommandEntry} entry @param {any[]} args @returns {any[] | null} */
function evalPredicate(entry, args) {
  if (!entry.when) return args;
  const res = entry.when(...args);
  if (!Array.isArray(res)) return res ? args : null;
  if (!res[0]) return null;
  return res.length > 1 ? res.slice(1) : args;
}

/** The active context: an ordered atom stack plus plugin flags. A key binding context tests them, and a deeper atom beats a shallower or unscoped one. */
export const context = {
  /** @type {Record<string, Array<{ value: ContextFlag }>>} */
  _flags: Object.create(null),

  /**
   * Add flags and return a disposer. A context tests a flag with `name == value` or `name != value`.
   * The newest live provider of a name gives its value. The disposer removes only its own providers.
   * @param {Record<string, ContextFlag>} flags
   * @returns {() => void}
   */
  add(flags) {
    /** @type {Array<[string, { value: ContextFlag }]>} */
    const held = [];
    for (const name in flags) {
      const entry = { value: /** @type {ContextFlag} */ (flags[name]) };
      const list = this._flags[name] || (this._flags[name] = []);
      list.push(entry);
      held.push([name, entry]);
    }
    return once(() => {
      for (const [name, entry] of held) {
        const list = /** @type {Array<{ value: ContextFlag }>} */ (this._flags[name]);
        list.splice(list.indexOf(entry), 1);
        if (list.length === 0) delete this._flags[name];
      }
    });
  },

  /**
   * The value of one flag, or undefined when no provider gives one. A provider that throws reads as absent, so it never breaks a key.
   * @param {string} name
   * @returns {string | undefined}
   */
  flag(name) {
    const v = this._flags[name]?.at(-1)?.value;
    if (typeof v !== "function") return v;
    try {
      const out = v();
      return out == null ? undefined : String(out);
    } catch (_e) {
      return undefined;
    }
  },

  /**
   * The active atoms, root first; the index is the depth. It holds "root", the atoms of the active pane,
   * and then "overlay" and the atoms of the focused overlay while one has the focus. A float adds no atom, because it holds no focus.
   * @returns {string[]}
   */
  stack() {
    const out = ["root"];
    pushAtoms(out, root.active);
    const top = root.focused;
    if (top && top !== root.active) {
      out.push("overlay");
      pushAtoms(out, top);
    }
    return out;
  },
};

// Add the atoms a view declares, or its name when it declares none.
/** @param {string[]} out @param {ViewLike | Overlay | null | undefined} view @returns {void} */
function pushAtoms(out, view) {
  if (!view) return;
  /** @type {unknown} */
  let own;
  try {
    own = typeof view.contexts === "function" ? view.contexts() : undefined;
  } catch (_e) {
    own = undefined;
  }
  const names = Array.isArray(own) ? own : [view.name];
  for (const raw of names) {
    // Keep a usable name only. A reserved or repeated atom would move another atom's depth.
    if (typeof raw !== "string" || raw === "" || raw === "root" || raw === "overlay") continue;
    if (out.indexOf(raw) < 0) out.push(raw);
  }
}

/**
 * Parse one context expression over `!`, `==`, `!=`, `&&`, `||`, and `()`. It throws an Error for bad syntax.
 * @param {string} source
 * @returns {ContextExpr}
 */
export function parseContext(source) {
  const text = String(source);
  const tokens = text.match(/&&|\|\||==|!=|[()!]|[A-Za-z_][\w-]*/g) || [];
  // The scan drops what it cannot read, so compare the tokens with the source before it parses.
  if (tokens.join("") !== text.replace(/\s+/g, "")) throw new Error("context: bad syntax in " + text);
  let at = 0;
  const peek = () => tokens[at];
  const take = () => tokens[at++];

  /** @returns {ContextNode} */
  const parsePrimary = () => {
    const t = take();
    if (t === undefined) throw new Error("context: unexpected end of " + source);
    if (t === "!") return { t: "not", x: parsePrimary() };
    if (t === "(") {
      const inner = parseOr();
      if (take() !== ")") throw new Error("context: missing ) in " + source);
      return inner;
    }
    if (!/^[A-Za-z_]/.test(t)) throw new Error("context: unexpected " + t + " in " + source);
    const op = peek();
    if (op === "==" || op === "!=") {
      take();
      const value = take();
      if (value === undefined) throw new Error("context: missing value in " + source);
      return { t: "eq", name: t, value, neg: op === "!=" };
    }
    return { t: "atom", name: t };
  };

  /** @returns {ContextNode} */
  const parseAnd = () => {
    let a = parsePrimary();
    while (peek() === "&&") {
      take();
      a = { t: "and", a, b: parsePrimary() };
    }
    return a;
  };

  /** @returns {ContextNode} */
  const parseOr = () => {
    let a = parseAnd();
    while (peek() === "||") {
      take();
      a = { t: "or", a, b: parseAnd() };
    }
    return a;
  };

  const node = parseOr();
  if (at !== tokens.length) throw new Error("context: trailing " + tokens[at] + " in " + source);
  /** @type {string[]} */
  const atoms = [];
  collectAtoms(node, atoms);
  return { source: text, node, atoms };
}

// Test one node against the atom depths and the flags.
/** @param {ContextNode} n @param {Record<string, number>} depths @returns {boolean} */
function matchContext(n, depths) {
  switch (n.t) {
    case "atom":
      return depths[n.name] !== undefined;
    case "eq": {
      const got = context.flag(n.name);
      return n.neg ? got !== n.value : got === n.value;
    }
    case "not":
      return !matchContext(n.x, depths);
    case "and":
      return matchContext(n.a, depths) && matchContext(n.b, depths);
    default:
      return matchContext(n.a, depths) || matchContext(n.b, depths);
  }
}

// Collect the atom names a node tests. A flag and a negation name no atom.
/** @param {ContextNode} n @param {string[]} out @returns {void} */
function collectAtoms(n, out) {
  switch (n.t) {
    case "atom":
      out.push(n.name);
      return;
    case "eq":
      return;
    case "not":
      return;
    default:
      collectAtoms(n.a, out);
      collectAtoms(n.b, out);
  }
}

// The atom depth index for the active context.
/** @returns {Record<string, number>} */
function currentDepths() {
  const stack = context.stack();
  /** @type {Record<string, number>} */
  const depths = Object.create(null);
  for (let i = 0; i < stack.length; i++) depths[/** @type {string} */ (stack[i])] = i;
  return depths;
}

// Rank the entries by the deepest atom the context matches, then by the newest registration.
/** @template {{ context: ContextExpr | null, order: number }} T @param {T[]} entries @param {boolean} [copy] @returns {T[]} */
function rankByContext(entries, copy = true) {
  // An unscoped set needs no stack walk, which is the common stroke.
  let scoped = false;
  for (const e of entries) {
    if (e.context) {
      scoped = true;
      break;
    }
  }
  if (!scoped) return copy ? entries.slice() : entries;

  const depths = currentDepths();
  /** @type {Array<{ entry: T, depth: number }>} */
  const hits = [];
  for (const e of entries) {
    if (!e.context) {
      hits.push({ entry: e, depth: 0 });
      continue;
    }
    if (!matchContext(e.context.node, depths)) continue;
    // The deepest atom the expression names that the stack holds.
    let depth = 0;
    for (const name of e.context.atoms) depth = Math.max(depth, depths[name] ?? 0);
    hits.push({ entry: e, depth });
  }
  hits.sort((a, b) => b.depth - a.depth || b.entry.order - a.entry.order);
  return hits.map((h) => h.entry);
}

// The share of a period a tick pulse can arrive early and still count, so timer jitter never skips a beat.
const TICK_EARLY_SHARE = 0.75;

/**
 * The key binding registry. New bindings run before old bindings. A space separates the strokes of a sequence.
 * @type {KeymapRegistry}
 */
export const keymap = {
  map: Object.create(null),
  prefixes: Object.create(null),
  /** @type {Pending | null} */
  pending: null,

  _seq: 0,

  // Register bindings under one context and return a disposer.
  /** @param {Record<string, KeyBinding | KeyBinding[]>} bindings @param {string} [ctx] @param {{ pending?: "chord" | "operator" }} [opts] @returns {() => void} */
  add(bindings, ctx, opts) {
    const expr = ctx ? parseContext(ctx) : null;
    const kind = opts && opts.pending === "operator" ? "operator" : "chord";
    /** @type {Array<[string, KeyEntry]>} */
    const added = [];
    for (const seq in bindings) {
      const key = normalizeSeq(seq);
      const value = /** @type {KeyBinding | KeyBinding[]} */ (bindings[seq]);
      /** @type {KeyBinding[]} */
      const list = Array.isArray(value) ? value.slice() : [value];
      /** @type {KeyEntry[]} */
      const fresh = list.map((fn) => ({ fn, context: expr, order: ++this._seq, pending: kind }));
      const prev = this.map[key];
      this.map[key] = prev ? fresh.concat(prev) : fresh;
      if (!prev) this._indexPrefix(key, true);
      for (const e of fresh) added.push([key, e]);
    }
    return once(() => {
      for (const [key, e] of added) {
        const cur = this.map[key];
        if (!cur) continue;
        const i = cur.indexOf(e);
        if (i >= 0) cur.splice(i, 1);
        if (cur.length > 0) continue;
        delete this.map[key];
        this._indexPrefix(key, false);
      }
      const p = this.pending;
      if (p && !this.prefixes[p.stroke]) {
        this.pending = null;
        root.syncTick();
      }
    });
  },

  // Return the entries a stroke offers here, by deepest matching atom and then newest first.
  /** @param {string} stroke @returns {KeyEntry[]} */
  candidates(stroke) {
    const entries = this.map[stroke];
    if (!entries) return [];
    return rankByContext(entries);
  },

  // The first stroke that runs each command here. `candidates` drops what the context shadows.
  /** @returns {Record<string, string>} */
  hints() {
    /** @type {Record<string, string>} */
    const hints = Object.create(null);
    for (const stroke in this.map) {
      const winner = this.candidates(stroke)[0];
      if (winner && typeof winner.fn === "string" && !(winner.fn in hints)) hints[winner.fn] = stroke;
    }
    return hints;
  },

  // Report the binding a stroke runs here and the bindings it shadows.
  /** @param {string} stroke @returns {{ stroke: string, winner: { binding: KeyBinding, context: string } | null, shadowed: Array<{ binding: KeyBinding, context: string }> }} */
  describe(stroke) {
    const key = normalizeSeq(stroke);
    const list = this.candidates(key).map((e) => ({ binding: e.fn, context: e.context ? e.context.source : "" }));
    return { stroke: key, winner: list.length ? /** @type {{ binding: KeyBinding, context: string }} */ (list[0]) : null, shadowed: list.slice(1) };
  },

  // Enter or drop a sequence under its first stroke. Each sequence in `map` is listed once, in the order `map` holds it.
  /** @param {string} key @param {boolean} present @returns {void} */
  _indexPrefix(key, present) {
    const sp = key.indexOf(" ");
    if (sp <= 0) return;
    const head = key.slice(0, sp);
    const keys = this.prefixes[head] || (this.prefixes[head] = []);
    if (present) {
      keys.push(key);
      return;
    }
    const at = keys.indexOf(key);
    // A sequence enters the index when it enters `map` and leaves `map` once, so it is still listed here.
    if (at < 0) throw new Error("keymap: the chord index lost " + key);
    keys.splice(at, 1);
    if (keys.length === 0) delete this.prefixes[head];
  },

  // Return how a sequence under `prefix` waits, or null when no active context matches.
  /** @param {string} prefix @returns {"chord" | "operator" | null} */
  _armKind(prefix) {
    const keys = this.prefixes[prefix];
    if (!keys) return null;
    const depths = currentDepths();
    for (const key of keys) {
      for (const e of this.map[key] || []) {
        if (!e.context || matchContext(e.context.node, depths)) return e.pending;
      }
    }
    return null;
  },

  // Return true while the keymap waits for the rest of a sequence.
  /** @returns {boolean} */
  owns() {
    return this.pending !== null;
  },

  // Return the pending stroke for the status bar.
  /** @returns {string} */
  pendingLabel() {
    return this.pending ? this.pending.stroke : "";
  },

  // Request a timer only for a pending chord, because an operator keeps its motion open.
  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    const p = this.pending;
    return p && p.kind === "chord" ? { periodMs: config.keymap.chordMs } : null;
  },

  // Run the prefix on its own after the chord wait ends.
  /** @returns {void} */
  tick() {
    const p = this.pending;
    if (!p || p.kind !== "chord") return;
    if (Date.now() - p.at < config.keymap.chordMs) return;
    this.pending = null;
    if (p.ev) this._perform(p.stroke, p.ev);
  },

  onKey(ev) {
    const s = strokeOf(ev);
    if (!s) return false;
    if (this.owns()) {
      const p = /** @type {Pending} */ (this.pending);
      this.pending = null;
      const chord = p.stroke + " " + s;
      if (this._perform(chord, ev)) return true;
      if (this._perform(p.stroke + " " + stripCtrl(s), ev)) return true;
      // The sequence did not resolve, so the second stroke runs on its own.
      return this._perform(s, ev);
    }
    const kind = this._armKind(s);
    if (kind) {
      this.pending = { stroke: s, kind, at: Date.now(), ev };
      return true;
    }
    return this._perform(s, ev);
  },

  // Run the stroke above an open modal when its winning binding names an `aboveModal` command. A sequence never starts here.
  /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
  performAboveModal(ev) {
    const s = strokeOf(ev);
    // Most strokes in a dialog are typed text with no binding, so they return before any lookup allocates.
    if (!s || !this.map[s]) return false;
    const winner = this.candidates(s)[0];
    return winner !== undefined && typeof winner.fn === "string" && command.performAboveModal(winner.fn, ev);
  },

  // Run the candidates in order until one claims the stroke.
  /** @param {string} stroke @param {Extract<HostEvent, { type: "key" }>} ev @returns {boolean} */
  _perform(stroke, ev) {
    for (const e of this.candidates(stroke)) {
      if (typeof e.fn === "function") {
        if (e.fn(ev) !== false) return true;
      } else if (command.perform(e.fn, ev)) {
        return true;
      }
    }
    return false;
  },
};

/** The key routes. A route chooses whether the keymap or the active view reads a key first. */
export const route = {
  /** @type {RouteEntry[]} */
  _list: [],

  _seq: 0,

  /**
   * Register one route under a context and return a disposer. The newest route with the deepest matching atom wins.
   * It throws a TypeError for another `where`, and an Error when `ctx` has bad syntax.
   * @param {RouteWhere} where
   * @param {string} [ctx] - a context expression, as `keymap.add` takes. No context applies everywhere.
   * @returns {() => void}
   */
  add(where, ctx) {
    if (where !== "keymap" && where !== "view") throw new TypeError("route.add: where must be keymap or view");
    /** @type {RouteEntry} */
    const entry = { where, context: ctx ? parseContext(ctx) : null, order: ++this._seq };
    this._list.push(entry);
    return once(() => {
      const i = this._list.indexOf(entry);
      if (i >= 0) this._list.splice(i, 1);
    });
  },

  /**
   * The route for the active context. The view reads first when no route matches.
   * @returns {RouteWhere}
   */
  reader() {
    if (this._list.length === 0) return "view";
    const hit = rankByContext(this._list, false)[0];
    return hit ? hit.where : "view";
  },
};

/**
 * Write `text` to the clipboard, tell the user the result, and emit `clipboard.copied`.
 * @param {string | null | undefined} text - null, undefined, or "" copies nothing.
 * @param {string | undefined} what - the name of the text in the notice. The default is "text".
 * @returns {number} the byte count, 0 for empty text, or -1 when the text is larger than the clipboard limit.
 */
export function copy(text, what) {
  const s = text == null ? "" : String(text);
  const bytes = s === "" ? 0 : term.copy(s);
  const label = what || "text";
  if (s === "") notify("info", "nothing to copy", "clipboard");
  else if (bytes < 0) notify("warn", "too large to copy · over " + term.clipboardMax + " bytes", "clipboard");
  else notify("info", "copied " + label + " · " + bytes + " bytes", "clipboard");
  events.emit("clipboard.copied", { what: label, text: s, bytes });
  return bytes;
}

/** @param {object | null | undefined} obj @param {string} message @returns {void} */
function requireView(obj, message) {
  const view = /** @type {Record<string, unknown> | null | undefined} */ (obj);
  if (!view || typeof view.draw !== "function" || typeof view.layout !== "function") throw new TypeError(message);
}

/** @type {WeakMap<object, object>} */
const VIEW_OWNER = new WeakMap();

/**
 * Claim a mounted view for `owner` without writing ownership state onto caller objects.
 * It throws a TypeError when another owner holds the view.
 * @param {object} view
 * @param {object} owner
 * @returns {void}
 */
export function claimView(view, owner) {
  if ((typeof view !== "object" && typeof view !== "function") || view === null) throw new TypeError("view ownership needs an object");
  if ((typeof owner !== "object" && typeof owner !== "function") || owner === null) throw new TypeError("view ownership needs an owner");
  const held = VIEW_OWNER.get(view);
  if (held && held !== owner) throw new TypeError("view already has an owner");
  VIEW_OWNER.set(view, owner);
}

/**
 * Release the claim of `owner` on `view`. It throws a TypeError when another owner holds the view, so a stale disposer cannot release a newer mount.
 * @param {object} view
 * @param {object} owner
 * @returns {void}
 */
export function releaseView(view, owner) {
  const held = VIEW_OWNER.get(view);
  if (held === undefined) return;
  if (held !== owner) throw new TypeError("view owner does not match");
  VIEW_OWNER.delete(view);
}

// The view tier emits these names, so it declares them and a headless bus refuses them.
events.declare([
  "ui.started",
  "ui.closed",
  "ui.resized",
  "ui.ticked",
  "key.pressed",
  "mouse.received",
  "paste.received",
  "focus.changed",
  "background.changed",
  "pane.focused",
  "pane.closed",
  "region.focused",
  "clipboard.copied",
]);

// This table maps a host event type to its core event name.
const HOST_TO_CORE_EVENT = /** @type {const} */ ({
  start: "ui.started",
  input_closed: "ui.closed",
  resize: "ui.resized",
  tick: "ui.ticked",
  key: "key.pressed",
  mouse: "mouse.received",
  paste: "paste.received",
  focus: "focus.changed",
  background: "background.changed",
});

/** A base class for a pane view. Each hook does nothing, and `layout` keeps the rect. A subclass overrides the hooks it needs. */
export class View {
  constructor() {
    /** @type {Rect} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }
  get name() {
    return "view";
  }
  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }
  /** @returns {void} */
  draw() {}
  /** @param {HostEvent} _ev @returns {boolean} */
  onKey(_ev) {
    return false;
  }
  /** @param {Extract<HostEvent, { type: "mouse" }>} _ev @returns {boolean} */
  onMouse(_ev) {
    return false;
  }
  /** @returns {void} */
  tick() {}
  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    return null;
  }
  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    return null;
  }
}

/** @param {Node} node @returns {ViewLike} */
function leafView(node) {
  if (node.shape.type !== "leaf") throw new Error("a leaf view is required");
  return node.shape.view;
}

/** One node of the pane tree: a leaf that shows a view, or a split of two nodes. */
export class Node {
  /** @param {NodeShape} shape */
  constructor(shape) {
    if (!shape || (shape.type !== "leaf" && shape.type !== "split")) throw new TypeError("a node needs a leaf or split shape");
    if (shape.type === "leaf") requireView(shape.view, "a view needs layout and draw methods");
    else if (!(shape.a instanceof Node) || !(shape.b instanceof Node)) throw new TypeError("a split needs two nodes");
    /** @type {Node | null} */
    this.parent = null;
    /** @type {Rect} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    /** @type {NodeShape} */
    this.shape = shape;
    if (shape.type === "split") {
      shape.a.parent = this;
      shape.b.parent = this;
    }
  }

  /** @param {ViewLike} view @returns {Node} */
  static leaf(view) {
    return new Node({ type: "leaf", view });
  }

  /** @param {"row" | "col"} kind @param {Node} a @param {Node} b @param {number | undefined} ratio @returns {Node} */
  static branch(kind, a, b, ratio) {
    const n = new Node({ type: "split", kind, a, b, ratio: ratio == null ? 0.5 : ratio });
    return n;
  }

  /** @param {"row" | "col"} kind @param {Node} a @param {Node} b @returns {void} */
  becomeSplit(kind, a, b) {
    if (this.shape.type !== "leaf") throw new TypeError("a split node cannot split again");
    this.shape = { type: "split", kind, a, b, ratio: 0.5 };
    a.parent = this;
    b.parent = this;
  }

  // Return the leaf that contains the cell. Return null outside this subtree.
  /** @param {number} col @param {number} row @returns {Node | null} */
  leafAt(col, row) {
    const r = this.rect;
    if (!contains(r, col, row)) return null;
    if (this.shape.type === "leaf") return this;
    return this.shape.a.leafAt(col, row) || this.shape.b.leafAt(col, row);
  }

  /** @param {Node[] | undefined} [out] @returns {Node[]} */
  leaves(out) {
    out = out || [];
    if (this.shape.type === "leaf") out.push(this);
    else {
      this.shape.a.leaves(out);
      this.shape.b.leaves(out);
    }
    return out;
  }

  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
    if (this.shape.type === "leaf") {
      this.shape.view.layout(rect);
      return;
    }
    if (this.shape.kind === "row") {
      const total = Math.max(0, rect.w - 1);
      const aw = clampChildSize(Math.round(total * this.shape.ratio), total);
      this.shape.a.layout({ x: rect.x, y: rect.y, w: aw, h: rect.h });
      this.shape.b.layout({ x: rect.x + aw + 1, y: rect.y, w: total - aw, h: rect.h });
    } else {
      const total = Math.max(0, rect.h - 1);
      const ah = clampChildSize(Math.round(total * this.shape.ratio), total);
      this.shape.a.layout({ x: rect.x, y: rect.y, w: rect.w, h: ah });
      this.shape.b.layout({ x: rect.x, y: rect.y + ah + 1, w: rect.w, h: total - ah });
    }
  }

  /** @param {Node | null} activeLeaf @returns {void} */
  draw(activeLeaf) {
    if (this.shape.type === "leaf") {
      callHook(this.shape.view, "draw", this === activeLeaf);
      return;
    }
    this.shape.a.draw(activeLeaf);
    this.shape.b.draw(activeLeaf);
    if (this.shape.kind === "row") {
      const splitA = this.shape.a;
      const x = splitA.rect.x + splitA.rect.w;
      for (let y = this.rect.y; y < this.rect.y + this.rect.h; y++) text(x, y, "│", "YukeRule");
    } else if (this.rect.w > 0) {
      const splitA = this.shape.a;
      const y = splitA.rect.y + splitA.rect.h;
      text(this.rect.x, y, "─".repeat(this.rect.w), "YukeRule");
    }
  }
}

/** @param {number} size @param {number} total @returns {number} */
function clampChildSize(size, total) {
  if (total <= 1) return total;
  return Math.max(1, Math.min(size, total - 1));
}

/** The status bar. It takes one row under the whole layout. A segment renders to a string or to nothing. */
export const status = {
  /** @type {StatusEntry[]} */
  _list: [],

  /**
   * Register a segment and return a disposer. It throws a TypeError for a missing `render`, a bad `side`, or an `order` that is not finite.
   * @param {StatusSegment} seg
   * @returns {() => void}
   */
  add(seg) {
    if (typeof seg.render !== "function") throw new TypeError("status.add needs a render function");
    const side = seg.side == null ? "left" : seg.side;
    if (side !== "left" && side !== "right") throw new TypeError("status.add: side must be left or right");
    const order = seg.order == null ? 0 : seg.order;
    if (!Number.isFinite(order)) throw new TypeError("status.add: order must be a finite number");
    const entry = { side, order, render: seg.render };
    this._list.push(entry);
    this._list.sort((a, b) => a.order - b.order);
    return once(() => {
      const i = this._list.indexOf(entry);
      if (i >= 0) this._list.splice(i, 1);
    });
  },

  /**
   * The text of one side now. A segment that renders nothing drops out of the join.
   * @param {"left" | "right"} which
   * @returns {string}
   */
  side(which) {
    // The frame asks each side on every draw, so the text grows in place and no array holds the parts.
    let out = "";
    for (const seg of this._list) {
      if (seg.side !== which) continue;
      // One bad provider must not take the frame with it.
      /** @type {string | null | undefined} */
      let t = "";
      try {
        t = seg.render();
      } catch (e) {
        fault(e, "status");
      }
      if (t) out = out ? out + " · " + t : String(t);
    }
    return out;
  },

  // The right side keeps the width it needs, so a long message never pushes it off the row.
  /** @param {number} x @param {number} y @param {number} w @returns {void} */
  draw(x, y, w) {
    if (w <= 0) return;
    fill(x, y, w, 1, "YukeBar");
    const right = this.side("right");
    const rw = right ? term.measure(right) : 0;
    if (right) text(x + Math.max(0, w - rw), y, clip(right, w), "YukeBar");
    const left = this.side("left");
    if (left) text(x, y, clip(left, Math.max(0, w - rw - 1)), "YukeBar");
  },
};

/** The screen: the pane tree, the overlay stack, the status bar, and the frame loop. `root` is the one instance. */
export class RootView {
  constructor() {
    /** @type {Node | null} */
    this.root_node = null;
    /** @type {Node | null} */
    this.activeLeaf = null;
    /** @type {Overlay[]} */
    this.overlays = [];
    /** @type {WeakMap<Overlay, () => void>} */
    this._closers = new WeakMap(); // the close function of each layer; every pop runs it once
    /** @type {Node[]} */
    this._leafScratch = [];
    /** @type {TickableEntry[]} */
    this.tickables = [];
    // The last tick each layer received. A pulse for the engine or a faster layer never runs a layer before its period.
    /** @type {WeakMap<object, number>} */
    this._tickedAt = new WeakMap();
    /** @type {Node | null} */
    this._capture = null; // the leaf that owns the drag, from press to release
    /** @type {boolean} */
    this._needsDraw = false; // the host paints once after it drains the event queue
    /** @type {boolean} */
    this._layoutDirty = true;
    /** @type {boolean} */
    this._started = false;
  }

  /** The view in the focused pane, or null when the tree is empty. */
  get active() {
    return this.activeLeaf ? leafView(this.activeLeaf) : null;
  }

  /**
   * Replace the pane tree and focus its first leaf. Each view that leaves the tree gets a `pane.closed` event.
   * It throws a TypeError when a view shows twice or another owner holds it.
   * @param {Node | null} node
   * @returns {void}
   */
  setRoot(node) {
    const leaves = node ? node.leaves() : [];
    const next = leaves.map(leafView);
    const seen = new Set();
    for (const view of next) {
      if (seen.has(view)) throw new TypeError("a root cannot mount a view twice");
      seen.add(view);
      if (this.overlays.indexOf(view) >= 0) throw new TypeError("a root cannot mount a view twice");
      const owner = VIEW_OWNER.get(view);
      if (owner && owner !== this) throw new TypeError("view already has an owner");
    }
    for (const view of next) claimView(view, this);
    const gone = this.root_node ? this.root_node.leaves().map(leafView) : [];
    if (node) node.parent = null;
    this.root_node = node;
    this.activeLeaf = null;
    this._capture = null;
    // The first leaf takes the focus through the same path, so it runs `onFocus` like any other.
    if (node) this._setActiveLeaf(/** @type {Node} */ (leaves[0]));
    // A replaced tree drops its panes, so each owner hears it the way a close tells them.
    const kept = node ? node.leaves().map(leafView) : [];
    for (const v of gone) {
      if (kept.indexOf(v) >= 0) continue;
      releaseView(v, this);
      events.emit("pane.closed", v);
    }
    this.invalidate();
  }

  // Move the active leaf. A new leaf gets `onFocus`, so a pane can reset its caret.
  /** @param {Node | null} leaf @returns {void} */
  _setActiveLeaf(leaf) {
    if (!leaf || leaf === this.activeLeaf) return;
    this.activeLeaf = leaf;
    // A listener reads the pane focus before the pane itself, which is the order advice gave it.
    const view = leafView(leaf);
    events.emit("pane.focused", view);
    callHook(view, "onFocus");
    this.invalidatePaint();
  }

  /**
   * Focus the pane that shows `view`. Return false when the view is not in the tree.
   * @param {ViewLike | null} view
   * @returns {boolean}
   */
  focusView(view) {
    if (!view || !this.root_node) return false;
    for (const leaf of this.root_node.leaves()) {
      if (leafView(leaf) === view) {
        this._setActiveLeaf(leaf);
        return true;
      }
    }
    return false;
  }

  // Send the event to the leaf under the pointer; a press focuses and captures it, so a drag that leaves it still lands.
  /** @param {Extract<HostEvent, { type: "mouse" }>} ev @returns {boolean} */
  routeMouse(ev) {
    if (this._capture && (ev.event === "drag" || ev.event === "release")) {
      const held = this._capture;
      if (ev.event === "release") this._capture = null;
      const live = this.root_node && this.root_node.leaves().indexOf(held) >= 0;
      return live ? !!callHook(leafView(held), "onMouse", ev) : false;
    }
    const leaf = this.root_node ? this.root_node.leafAt(ev.col, ev.row) : null;
    if (!leaf) return false;
    if (ev.event === "press" && !isWheel(ev.button)) {
      // The leaf came from the live tree, so it needs no membership walk.
      this._setActiveLeaf(leaf);
      if (ev.button === "left") this._capture = leaf;
    }
    return !!callHook(leafView(leaf), "onMouse", ev);
  }

  /**
   * Split the focused pane and show `view` in the new pane, which gets the focus. Prefer `tui.split`, which closes the pane when its block stops.
   * It throws a TypeError when `view` has no `layout` and `draw` or already shows.
   * @param {"row" | "col"} kind - "row" puts the new pane on the right, and "col" puts it below.
   * @param {ViewLike} view
   * @returns {Node | null} the new leaf, or null when no pane has the focus.
   */
  split(kind, view) {
    const leaf = this.activeLeaf;
    if (!leaf) return null;
    requireView(view, "a view needs layout and draw methods");
    for (const existing of /** @type {Node} */ (this.root_node).leaves()) if (leafView(existing) === view) throw new TypeError("a root cannot mount a view twice");
    if (this.overlays.includes(view)) throw new TypeError("a root cannot mount a view twice");
    claimView(view, this);
    const add = Node.leaf(view);
    leaf.becomeSplit(kind, Node.leaf(leafView(leaf)), add);
    this._setActiveLeaf(add);
    this.invalidate();
    return add;
  }

  /**
   * Close the pane that shows `view`, or the focused pane, and emit `pane.closed`. A view no longer in the tree closes nothing.
   * The last pane does not close.
   * @param {ViewLike} [view]
   * @returns {void}
   */
  close(view) {
    const leaf = view ? (this.root_node?.leaves().find((held) => leafView(held) === view) ?? null) : this.activeLeaf;
    const p = leaf && leaf.parent;
    if (!p) return;
    if (p.shape.type !== "split") throw new Error("a leaf parent must be a split");
    const sib = p.shape.a === leaf ? p.shape.b : p.shape.a;
    if (sib.shape.type === "leaf") p.shape = { type: "leaf", view: sib.shape.view };
    else {
      p.shape = { type: "split", kind: sib.shape.kind, ratio: sib.shape.ratio, a: sib.shape.a, b: sib.shape.b };
      p.shape.a.parent = p;
      p.shape.b.parent = p;
    }
    // Only a closed focused pane moves the focus. A focused leaf sibling now lives in `p`, so the focus follows it there.
    if (this.activeLeaf === leaf) this._setActiveLeaf(/** @type {Node} */ (p.leaves()[0]));
    else if (this.activeLeaf === sib) this.activeLeaf = p;
    // The tree drops the view here, so the owner learns that its pane left.
    const removed = leafView(leaf);
    releaseView(removed, this);
    events.emit("pane.closed", removed);
    this.invalidate();
  }

  /**
   * Focus the nearest pane in a direction: "h" left, "j" down, "k" up, "l" right. With no pane there, the focus stays.
   * @param {"h" | "j" | "k" | "l"} d
   * @returns {void}
   */
  focusDir(d) {
    if (!this.activeLeaf) return;
    const cur = this.activeLeaf.rect;
    const cx = cur.x + cur.w / 2;
    const cy = cur.y + cur.h / 2;
    let best = null;
    let bestScore = Infinity;
    for (const leaf of /** @type {Node} */ (this.root_node).leaves()) {
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
    if (best) this._setActiveLeaf(best);
  }

  /**
   * Move the focus `step` panes through the tree order, and wrap at each end.
   * @param {number} step
   * @returns {void}
   */
  focusCycle(step) {
    if (!this.root_node) return;
    const leaves = this.root_node.leaves();
    if (leaves.length === 0) return;
    let i = leaves.indexOf(/** @type {Node} */ (this.activeLeaf));
    if (i < 0) i = 0;
    this._setActiveLeaf(/** @type {Node} */ (leaves[(i + step + leaves.length) % leaves.length]));
  }

  /** @param {Tickable} tickable @returns {TickableEntry | undefined} */
  _tickableEntry(tickable) {
    for (const e of this.tickables) if (e.tickable === tickable) return e;
    return undefined;
  }

  /**
   * Report whether a tickable is registered, so a caller never reads the entry list itself.
   * @param {Tickable} tickable
   * @returns {boolean}
   */
  hasTickable(tickable) {
    return this._tickableEntry(tickable) !== undefined;
  }

  /**
   * Add a tickable to the frame loop and return it. After the start, it gets `onStart` at once. Prefer `tui.tickable`, which removes it when its block stops.
   * A second registration shares one entry, so one owner cannot stop a service another still holds.
   * @param {Tickable} tickable
   * @returns {Tickable}
   */
  addTickable(tickable) {
    const held = this._tickableEntry(tickable);
    if (held) {
      held.refs += 1;
      return tickable;
    }
    /** @type {TickableEntry} */
    const entry = { tickable, refs: 1, started: false };
    this.tickables.push(entry);
    if (this._started) {
      // A hook that throws must not leave a service behind that the failed scope cannot revert.
      try {
        callHook(tickable, "onStart");
      } catch (e) {
        const i = this.tickables.indexOf(entry);
        if (i >= 0) this.tickables.splice(i, 1);
        throw e;
      }
      entry.started = true;
    }
    this.syncTick();
    return tickable;
  }

  /**
   * Drop one registration. The last one removes the entry, and only a started service gets `onStop`.
   * @param {Tickable} tickable
   * @returns {void}
   */
  removeTickable(tickable) {
    const entry = this._tickableEntry(tickable);
    if (!entry) return;
    entry.refs -= 1;
    if (entry.refs > 0) return;
    const i = this.tickables.indexOf(entry);
    if (i >= 0) this.tickables.splice(i, 1);
    try {
      if (entry.started) callHook(tickable, "onStop");
    } finally {
      // The timer must return to the truth even when a stop hook throws.
      this.syncTick();
    }
  }

  /**
   * The widget that a nav binding drives, from the layer that reads the keyboard, or null when that layer has none.
   * @returns {NavTarget | null}
   */
  navTarget() {
    return /** @type {NavTarget | null} */ (callHook(this.focused, "navTarget") || null);
  }

  /** The layer that reads the keys and owns the cursor: the top modal overlay, else the active view, else null. */
  get focused() {
    for (let i = this.overlays.length - 1; i >= 0; i--) {
      const layer = /** @type {Overlay} */ (this.overlays[i]);
      if (layer.modal !== false) return layer;
    }
    return this.active;
  }

  /**
   * Show `layer` on top of the overlay stack and return it. A modal layer ends a waiting key sequence.
   * Prefer `tui.overlay`, which closes the layer when its block stops.
   * It throws a TypeError when the layer has no `layout` and `draw` or already shows.
   * @param {Overlay} layer
   * @returns {Overlay}
   */
  pushOverlay(layer) {
    requireView(layer, "pushOverlay needs layout and draw methods");
    if (this.overlays.indexOf(layer) >= 0) throw new TypeError("an overlay cannot be pushed twice");
    if (this.root_node && this.root_node.leaves().some((leaf) => leafView(leaf) === layer)) throw new TypeError("a root cannot mount a view twice");
    claimView(layer, this);
    this.overlays.push(layer);
    // A modal takes the keys, so a sequence that started below it can never finish.
    if (layer.modal !== false) keymap.pending = null;
    this.invalidate();
    return layer;
  }

  /**
   * Run `onClose` once when `layer` leaves the stack, by any pop. A later call replaces it, so the newest owner answers.
   * @param {Overlay} layer
   * @param {() => void} onClose
   * @returns {void}
   */
  closeWith(layer, onClose) {
    this._closers.set(layer, onClose);
  }

  /**
   * Take `layer`, or the top layer, off the stack, and run its close function once.
   * A layer that does not show still runs its close function. An empty stack does nothing.
   * @param {Overlay} [layer]
   * @returns {void}
   */
  popOverlay(layer) {
    const target = layer ?? this.overlays[this.overlays.length - 1];
    if (!target) return;
    const closer = this._closers.get(target);
    const i = this.overlays.indexOf(target);
    if (i >= 0) {
      this.overlays.splice(i, 1);
      releaseView(target, this);
    }
    this.invalidate();
    // The close function leaves before it runs, so a pop inside it finds nothing to run again.
    if (!closer) return;
    this._closers.delete(target);
    closer();
  }

  /**
   * Ask for a new layout and a frame. The host paints once after the queue drains, so a burst costs one paint.
   * @returns {void}
   */
  invalidate() {
    this._needsDraw = true;
    this._layoutDirty = true;
  }

  /**
   * Ask for a frame without a new layout.
   * @returns {void}
   */
  invalidatePaint() {
    this._needsDraw = true;
  }

  // Paint if anything asked for it. The host calls this after it drains the event queue.
  /** @returns {void} */
  flush() {
    if (!this._needsDraw) return;
    this._needsDraw = false;
    this.draw();
  }

  /** @param {(layer: Overlay | Tickable, isTickable: boolean) => void} fn @returns {void} */
  _forEachTickable(fn) {
    if (this.root_node) {
      // One scratch list serves every draw. A nested pass takes a fresh list, and a throw still clears the scratch.
      const scratch = this._leafScratch;
      const leaves = this.root_node.leaves(scratch.length === 0 ? scratch : []);
      try {
        for (const leaf of leaves) fn(leafView(leaf), false);
      } finally {
        leaves.length = 0;
      }
    }
    for (const layer of this.overlays) fn(layer, false);
    for (const e of this.tickables.slice()) fn(e.tickable, true);
  }

  /** @returns {void} */
  draw() {
    if (!this.root_node && this.overlays.length === 0) return;
    term.beginFrame();
    // The bar owns the last row, so every pane rect below derives from the shorter height.
    const barY = term.height - 1;
    fill(0, 0, term.width, term.height, "Normal");
    const needsLayout = this._layoutDirty;
    this._layoutDirty = false;
    if (needsLayout) {
      try {
        if (this.root_node) this.root_node.layout({ x: 0, y: 0, w: term.width, h: Math.max(0, barY) });
        const bounds = { x: 0, y: 0, w: term.width, h: term.height };
        for (const layer of this.overlays) callHook(layer, "layout", bounds);
      } catch (error) {
        this._layoutDirty = true;
        throw error;
      }
    }
    if (this.root_node) this.root_node.draw(this.activeLeaf);
    if (barY >= 0) status.draw(0, barY, term.width);
    const focused = this.focused;
    for (const layer of this.overlays) {
      callHook(layer, "draw", layer === focused);
    }
    const c = /** @type {{ x: number, y: number, visible: boolean } | null} */ (callHook(focused, "cursor"));
    if (c && c.visible) term.cursor(c.x, c.y, true);
    else term.cursor(0, 0, false);
    term.endFrame();
    this.syncTick();
  }

  /** @returns {void} */
  syncTick() {
    /** @type {number | null} */
    let period = null;
    this._forEachTickable((layer) => {
      const t = /** @type {{ periodMs: number } | null} */ (callHook(layer, "needsTick"));
      if (!t) return;
      const ms = t.periodMs;
      period = period == null ? ms : Math.min(period, ms);
    });
    if (period != null) term.setNeedsTick(true, period);
    else term.setNeedsTick(false);
  }

  // Tick each layer whose period elapsed, and answer whether any did. A pulse can arrive a quarter period early.
  /** @returns {boolean} */
  tickLayers() {
    const now = Date.now();
    let ticked = false;
    this._forEachTickable((layer, isTickable) => {
      const t = /** @type {{ periodMs: number } | null} */ (callHook(layer, "needsTick"));
      if (!t) return;
      const last = this._tickedAt.get(layer);
      // A clock that steps back reads as elapsed, so a layer never waits for the clock to catch up.
      if (last !== undefined && now >= last && now - last < t.periodMs * TICK_EARLY_SHARE) return;
      // A service can remove itself inside `needsTick`, so a stale one must not still get `tick`.
      if (isTickable && !this.hasTickable(/** @type {Tickable} */ (layer))) return;
      this._tickedAt.set(layer, now);
      callHook(layer, "tick");
      ticked = true;
    });
    return ticked;
  }

  // A modal overlay consumes the event even when the overlay has no requested hook.
  /** @param {"onKey" | "onMouse"} method @param {RootEvent} ev @returns {boolean} */
  _consumedByOverlay(method, ev) {
    let i = this.overlays.length - 1;
    while (i >= 0) {
      const layer = /** @type {Overlay} */ (this.overlays[i]);
      // A float yields to a pending chord, so its own Tab never cuts a sequence short.
      if (layer.modal === false && method === "onKey" && keymap.owns()) { i--; continue; }
      const modal = layer.modal !== false;
      const handled = callHook(layer, method, ev);
      if (modal || handled) return true;
      // A hook can remove layers, so resume below its current position.
      const at = this.overlays.indexOf(layer);
      i = at < 0 ? Math.min(i - 1, this.overlays.length - 1) : at - 1;
    }
    return false;
  }

  /** @param {RootEvent} ev @returns {void} */
  onEvent(ev) {
    const name = HOST_TO_CORE_EVENT[ev.type];
    // The table pairs each host type with its event, so the payload fits the name.
    if (name) events.emit(name, /** @type {any} */ (ev));
    if (ev.type === "input_closed") {
      term.setNeedsTick(false);
      term.quit();
      return;
    }
    if (ev.type === "start" || ev.type === "resize") {
      if (ev.type === "start" && !this._started) {
        this._started = true;
        for (const e of this.tickables.slice()) {
          // A hook can remove a later tickable, so start only what the pass still holds.
          if (e.started || !this.hasTickable(e.tickable)) continue;
          e.started = true;
          callHook(e.tickable, "onStart");
        }
      }
      this.invalidate();
      return;
    }
    // A pulse that ticks no layer changes no view, so it draws nothing. A tick that changes a size asks for the layout itself.
    if (ev.type === "tick") {
      if (this.tickLayers()) this.invalidatePaint();
      return;
    }
    // Redraw on focus gain. A focus loss changes no view state.
    if (ev.type === "focus") {
      if (ev.focused) this.invalidate();
      return;
    }
    if (ev.type === "key" || ev.type === "paste") {
      if (ev.type === "key" && ev.event === "release") return;
      // A paste completes no sequence, so it ends the wait rather than leaving it armed.
      if (ev.type === "paste" && keymap.owns()) keymap.pending = null;
      // A command such as quit runs before an open dialog takes its key.
      const aboveModal = ev.type === "key" && this.overlays.length !== 0 && this.focused !== this.active && !keymap.owns() && keymap.performAboveModal(ev);
      if (!aboveModal && !this._consumedByOverlay("onKey", ev)) {
        // The keymap reads a key first while it waits for a sequence, or where a route skips the view.
        const keymapFirst = keymap.owns() || route.reader() === "keymap";
        const viewTakes = !keymapFirst && callHook(this.active, "onKey", ev);
        if (!viewTakes && ev.type === "key") keymap.onKey(ev);
      }
    } else if (ev.type === "mouse") {
      if (!this._consumedByOverlay("onMouse", ev)) this.routeMouse(ev);
    } else {
      // A background change alters no view: a theme that follows it repaints through `style`.
      return;
    }
    this.invalidate();
  }
}

/** The one root view of the process. */
export const root = new RootView();

// Each style change repaints `root`, so the core defaults register after it exists.
style.set({
  Normal: { fg: "fg", bg: "bg" },
  YukeBrand: { fg: "fg", bold: true },
  YukeStatus: { fg: "fg", dim: true },
  YukeRule: { fg: "fg", dim: true },
  YukeEmpty: { fg: "fg", dim: true },
  YukeBar: { fg: "fg", dim: true },
}, { default: true });

/** A synthetic esc key press. Every dialog cancels when it receives esc. */
export const ESC_PRESS = /** @type {Readonly<Extract<HostEvent, { type: "key" }>>} */ (Object.freeze({ type: "key", code: "esc", char: "", shifted: "", baseLayout: "", text: "", event: "press", mods: 0 }));

/**
 * Ask yuke to quit. A `quit.request` listener can stop the quit, for example while work runs.
 * The key, the palette, the slash word, and user code all call this, so they follow one rule.
 */
export function quit() {
  if (events.bail("quit.request")) return;
  term.quit();
}

// A bare key never quits. A stray key in a modal layer must not end the session.
command.add("quit", { run: quit, desc: "leave yuke", slash: true, aboveModal: true });
command.add("suspend", { run: () => term.suspend(), desc: "stop yuke so the shell can run fg", slash: true, aboveModal: true });
// The command sends esc to the focused dialog, and the dialog runs its own cancel. The `overlay` context binds it only while a dialog is open.
command.add("modal:cancel", { run: () => { if (root.focused !== root.active) callHook(root.focused, "onKey", ESC_PRESS); }, aboveModal: true });

root.addTickable(keymap);

globalThis.onEvent = (ev) => root.onEvent(ev);
globalThis.flushFrame = () => root.flush();
