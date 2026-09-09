import { clip } from "yuke:text-input";
import { normalizeSeq, stripCtrl, strokeOf } from "yuke:keys";
import { term } from "yuke:term";
import { callHook, config, defineConfig, Emitter, events } from "yuke:kernel";

export { config, defineConfig, Emitter, events };

/** @import { CommandAction, CommandEntry, CommandListing, CommandMeta, CommandPredicate, CommandRegistry, ContextExpr, ContextFlag, ContextNode, KeyBinding, KeyEntry, KeymapRegistry, NavTarget, NodeShape, Overlay, Pending, Rect, RootEvent, RouteEntry, RouteWhere, SlotEntry, StatusEntry, StatusSegment, StyleConfig, StyleGroup, Tickable, TickableEntry, ViewLike } from "./types/core.js" */

// True for a wheel button. The wheel scrolls a pane but never moves the focus.
/** @param {string} button @returns {boolean} */
export function isWheel(button) {
  return button === "wheel_up" || button === "wheel_down" || button === "wheel_left" || button === "wheel_right";
}

// Bound a link chain, so a cycle falls back instead of looping for ever.
const link_depth_max = 100;

// The highlight groups are monochrome: emphasis is weight and inversion, `Normal` is `reset`, and `danger` is the only color.
/** @type {StyleConfig} */
export const style = {
  palette: {
    fg: "reset",
    bg: "reset",
    danger: "red",
  },
  groups: Object.assign(Object.create(null), {
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
  }),
  /** @type {Record<string, number>} */
  _refs: Object.create(null),
  _cache: Object.create(null),

  // Register absent groups and return a disposer that drops each group after its last reference.
  /** @param {Record<string, StyleGroup>} groups @returns {() => void} */
  add(groups) {
    /** @type {string[]} */
    const held = [];
    for (const name in groups) {
      const refs = this._refs[name];
      if (!(name in this.groups)) {
        this.groups[name] = /** @type {StyleGroup} */ (groups[name]);
        this._refs[name] = 1;
        held.push(name);
      } else if (refs !== undefined) {
        // A group the map held before any `add`, such as a built-in, takes no reference.
        this._refs[name] = refs + 1;
        held.push(name);
      }
    }
    if (held.length === 0) return () => {};
    this.invalidate();

    return once(() => {
      for (const name of held) {
        const refs = this._refs[name];
        if (refs !== undefined && refs > 1) {
          this._refs[name] = refs - 1;
          continue;
        }
        delete this._refs[name];
        delete this.groups[name];
      }
      this.invalidate();
    });
  },

  resolve(name) {
    const cached = this._cache[name];
    if (cached) return cached;

    /** @type {StyleGroup | undefined | null} */
    let def = this.groups[name];
    for (let i = 0; def && def.link && i < link_depth_max; i++) def = this.groups[def.link];
    if (def && def.link) def = null;

    /** @type {import("yuke:term").Style} */
    const out = {};
    if (def) {
      if (def.bg !== undefined) out.bg = /** @type {import("yuke:term").Color} */ (this.palette[def.bg] !== undefined ? this.palette[def.bg] : def.bg);
      if (def.bold) out.bold = true;
      if (def.dim) out.dim = true;
      if (def.italic) out.italic = true;
      if (def.underline) out.underline = true;
      if (def.reverse) out.reverse = true;
    }
    const fg = def && def.fg !== undefined ? def.fg : "fg";
    out.fg = /** @type {import("yuke:term").Color} */ (this.palette[fg] !== undefined ? this.palette[fg] : fg);

    this._cache[name] = out;
    return out;
  },
  invalidate() {
    this._cache = Object.create(null);
  },
};

/** @param {number} x @param {number} y @param {number} w @param {number} h @param {string} group @returns {void} */
export function fill(x, y, w, h, group) {
  term.fill(x, y, w, h, style.resolve(group));
}

/** @param {number} x @param {number} y @param {string} s @param {string} group @returns {void} */
export function text(x, y, s, group) {
  term.text(x, y, s, style.resolve(group));
}

// Wrap a disposer so a second call does nothing.
/** @param {() => void} fn @returns {() => void} */
function once(fn) {
  let done = false;
  return () => {
    if (done) return;
    done = true;
    fn();
  };
}

// A command has a predicate and an action. A string predicate matches the active view.
/** @type {CommandRegistry} */
export const command = {
  map: Object.create(null),

  // Register a batch under one predicate; a later registration shadows an earlier one. `meta` marks a user action.
  add(predicate, map, meta) {
    const pred = normalizePredicate(predicate);
    /** @type {Array<[string, CommandEntry]>} */
    const added = [];
    for (const name in map) {
      const entry = { predicate: pred, perform: /** @type {CommandAction} */ (map[name]), meta: (meta && meta[name]) || null };
      const list = this.map[name] || (this.map[name] = []);
      list.unshift(entry);
      added.push([name, entry]);
    }
    return once(() => {
      for (const [name, entry] of added) {
        const list = this.map[name];
        if (!list) continue;
        const i = list.indexOf(entry);
        if (i >= 0) list.splice(i, 1);
        if (list.length === 0) delete this.map[name];
      }
    });
  },

  // A rejected predicate lets the next entry run.
  perform(name, ...args) {
    const found = selectCommand(this.map[name], args);
    if (!found) return false;
    found.entry.perform(...found.args);
    return true;
  },

  // A throwing predicate counts as available, so one bad predicate never empties a listing.
  available(name) {
    return isAvailable(this.map[name]);
  },

  // List the available commands with metadata in title order. A keymap target has none, so no palette lists it.
  list() {
    /** @type {CommandListing[]} */
    const out = [];
    for (const name in this.map) {
      const list = /** @type {CommandEntry[]} */ (this.map[name]);
      const meta = metaOf(list);
      if (meta && isAvailable(list)) out.push({ name, title: meta.title, description: meta.description, slash: meta.slash || null, args: !!meta.args });
    }
    // Code-unit order: localeCompare NFC-normalizes and traps in ReleaseSafe QuickJS.
    return out.sort((a, b) => (a.title < b.title ? -1 : a.title > b.title ? 1 : 0));
  },
};

// The newest metadata in the list, so a plain shadow keeps the listing under it.
/** @param {CommandEntry[]} list @returns {CommandMeta | null} */
function metaOf(list) {
  for (const entry of list) if (entry.meta) return entry.meta;
  return null;
}

// Return the newest entry whose predicate accepts, with the arguments to run it with.
/** @param {CommandEntry[] | undefined} list @param {any[]} args @returns {{ entry: CommandEntry, args: any[] } | null} */
function selectCommand(list, args) {
  if (!list) return null;
  for (const entry of list) {
    const call = evalPredicate(entry, args);
    if (call !== null) return { entry, args: call };
  }
  return null;
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
  if (!entry.predicate) return args;
  const res = entry.predicate(...args);
  if (!Array.isArray(res)) return res ? args : null;
  if (!res[0]) return null;
  return res.length > 1 ? res.slice(1) : args;
}

/** @param {string | CommandPredicate | null} predicate @returns {CommandPredicate | null} */
function normalizePredicate(predicate) {
  if (predicate == null) return null;
  if (typeof predicate === "string") {
    return () => (root.active && root.active.name === predicate ? [true, root.active] : [false]);
  }
  return predicate;
}

// The active context: an ordered atom stack plus plugin flags, where a deeper atom beats a shallower or unscoped one.
export const context = {
  /** @type {Record<string, ContextFlag>} */
  _flags: Object.create(null),

  // Set flags and return a restoring disposer; a function value resolves at match time, so a live mode needs no update.
  /** @param {Record<string, ContextFlag>} flags @returns {() => void} */
  add(flags) {
    /** @type {Array<[string, ContextFlag | undefined]>} */
    const prev = [];
    for (const name in flags) {
      prev.push([name, this._flags[name]]);
      this._flags[name] = /** @type {ContextFlag} */ (flags[name]);
    }
    return once(() => {
      for (const [name, was] of prev) {
        if (was === undefined) delete this._flags[name];
        else this._flags[name] = was;
      }
    });
  },

  // The value of one flag. A throwing provider reads as absent, so it never breaks a key.
  /** @param {string} name @returns {string | undefined} */
  flag(name) {
    const v = this._flags[name];
    if (typeof v !== "function") return v;
    try {
      const out = v();
      return out == null ? undefined : String(out);
    } catch (_e) {
      return undefined;
    }
  },

  // The atom stack, root first; the index is the depth. A float adds no atom, because it holds no focus.
  /** @returns {string[]} */
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

// Parse one context expression over `!`, `==`, `!=`, `&&`, `||`, and `()`.
/** @param {string} source @returns {ContextExpr} */
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

// Return the depth of the deepest atom the expression names that the stack holds.
/** @param {ContextExpr} expr @param {Record<string, number>} depths @returns {number} */
function depthOf(expr, depths) {
  let depth = 0;
  for (const name of expr.atoms) {
    const d = depths[name];
    if (d !== undefined && d > depth) depth = d;
  }
  return depth;
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
/** @template {{ context: ContextExpr | null, order: number }} T @param {T[]} entries @returns {T[]} */
function rankByContext(entries) {
  // An unscoped set needs no stack walk, which is the common stroke.
  let scoped = false;
  for (const e of entries) {
    if (e.context) {
      scoped = true;
      break;
    }
  }
  if (!scoped) return entries.slice();

  const depths = currentDepths();
  /** @type {Array<{ entry: T, depth: number }>} */
  const hits = [];
  for (const e of entries) {
    if (!e.context) {
      hits.push({ entry: e, depth: 0 });
      continue;
    }
    if (!matchContext(e.context.node, depths)) continue;
    hits.push({ entry: e, depth: depthOf(e.context, depths) });
  }
  hits.sort((a, b) => b.depth - a.depth || b.entry.order - a.entry.order);
  return hits.map((h) => h.entry);
}

// New bindings run before old bindings. A space separates chord strokes.
/** @type {KeymapRegistry} */
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
      for (const e of fresh) added.push([key, e]);
    }
    this._rebuildPrefixes();
    return once(() => {
      for (const [key, e] of added) {
        const cur = this.map[key];
        if (!cur) continue;
        const i = cur.indexOf(e);
        if (i >= 0) cur.splice(i, 1);
        if (cur.length === 0) delete this.map[key];
      }
      this._rebuildPrefixes();
    });
  },

  // Return the entries a stroke offers here, by deepest matching atom and then newest first.
  /** @param {string} stroke @returns {KeyEntry[]} */
  candidates(stroke) {
    const entries = this.map[stroke];
    if (!entries) return [];
    return rankByContext(entries);
  },

  // Report the binding a stroke runs here and the bindings it shadows.
  /** @param {string} stroke @returns {{ stroke: string, winner: { binding: KeyBinding, context: string } | null, shadowed: Array<{ binding: KeyBinding, context: string }> }} */
  describe(stroke) {
    const key = normalizeSeq(stroke);
    const list = this.candidates(key).map((e) => ({ binding: e.fn, context: e.context ? e.context.source : "" }));
    return { stroke: key, winner: list.length ? /** @type {{ binding: KeyBinding, context: string }} */ (list[0]) : null, shadowed: list.slice(1) };
  },

  _rebuildPrefixes() {
    this.prefixes = Object.create(null);
    for (const key in this.map) {
      const sp = key.indexOf(" ");
      if (sp <= 0) continue;
      const head = key.slice(0, sp);
      const keys = this.prefixes[head] || (this.prefixes[head] = []);
      keys.push(key);
    }
    const p = this.pending;
    if (p && !this.prefixes[p.stroke]) {
      this.pending = null;
      root.syncTick();
    }
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

  // Arm a pending stroke of `kind`.
  /** @param {string} stroke @param {"chord" | "operator"} kind @param {Extract<HostEvent, { type: "key" }> | null} [ev] @returns {void} */
  arm(stroke, kind, ev) {
    this.pending = { stroke, kind, at: Date.now(), ev: ev || null };
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
      this.arm(s, kind, ev);
      return true;
    }
    return this._perform(s, ev);
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

// A route chooses whether the keymap or the view reads a key first.
export const route = {
  /** @type {RouteEntry[]} */
  _list: [],

  _seq: 0,

  // Register one route under a context and return a disposer.
  /** @param {RouteWhere} where @param {string} [ctx] @returns {() => void} */
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

  // The route for the active context. A view reads first when no route matches.
  /** @returns {RouteWhere} */
  reader() {
    if (this._list.length === 0) return "view";
    const hit = rankByContext(this._list)[0];
    return hit ? hit.where : "view";
  },
};

// A widget asks for a value it does not own. The nearest class answers first, then the newest provider.
export const slot = {
  /** @type {Map<object, Record<string, SlotEntry[]>>} */
  _map: new Map(),

  // Register a provider for one named slot on a class and return a disposer.
  /** @param {Function} target @param {string} name @param {(obj: any, arg?: any) => unknown} fn @returns {() => void} */
  add(target, name, fn) {
    if (typeof target !== "function" || !target.prototype) throw new TypeError("slot: target must be a class");
    if (typeof fn !== "function") throw new TypeError("slot: fn must be a function");
    const proto = target.prototype;
    let names = this._map.get(proto);
    if (!names) {
      /** @type {Record<string, SlotEntry[]>} */
      const fresh = Object.create(null);
      this._map.set(proto, fresh);
      names = fresh;
    }
    /** @type {SlotEntry} */
    const entry = { fn };
    const list = names[name] || (names[name] = []);
    list.unshift(entry);
    return once(() => {
      const held = this._map.get(proto);
      const cur = held ? held[name] : undefined;
      if (!held || !cur) return;
      const i = cur.indexOf(entry);
      if (i >= 0) cur.splice(i, 1);
      if (cur.length === 0) delete held[name];
      if (Object.keys(held).length === 0) this._map.delete(proto);
    });
  },

  // The first value a provider gives for `obj`. A null or undefined answer passes the slot on.
  /** @param {object | null} obj @param {string} name @param {any} [arg] @returns {any} */
  get(obj, name, arg) {
    if (!obj) return null;
    let proto = Object.getPrototypeOf(obj);
    // A subclass reads the slot its base class declares.
    while (proto) {
      const names = this._map.get(proto);
      const list = names ? names[name] : undefined;
      if (list) {
        // A provider may dispose itself, so walk a copy the way the event bus does.
        for (const e of list.slice()) {
          // One bad provider must not take the frame with it.
          try {
            const v = e.fn(obj, arg);
            if (v != null) return v;
          } catch (err) {
            events.emit("ext.error", err, name);
          }
        }
      }
      proto = Object.getPrototypeOf(proto);
    }
    return null;
  },
};

// Write `text` to the clipboard, emit `clipboard.copied`, and return the byte count or -1.
/** @param {string | null | undefined} text @param {string | undefined} what @returns {number} */
export function copy(text, what) {
  const s = text == null ? "" : String(text);
  const bytes = s === "" ? 0 : term.copy(s);
  events.emit("clipboard.copied", { what: what || "text", text: s, bytes });
  return bytes;
}

/** @param {object | null | undefined} obj @param {string} message @returns {void} */
function requireView(obj, message) {
  const view = /** @type {Record<string, unknown> | null | undefined} */ (obj);
  if (!view || typeof view.draw !== "function" || typeof view.layout !== "function") throw new TypeError(message);
}

/** @type {WeakMap<object, object>} */
const VIEW_OWNER = new WeakMap();

// Claim a mounted view without writing ownership state onto caller objects.
/** @param {object} view @param {object} owner @returns {void} */
export function claimView(view, owner) {
  if ((typeof view !== "object" && typeof view !== "function") || view === null) throw new TypeError("view ownership needs an object");
  if ((typeof owner !== "object" && typeof owner !== "function") || owner === null) throw new TypeError("view ownership needs an owner");
  const held = VIEW_OWNER.get(view);
  if (held && held !== owner) throw new TypeError("view already has an owner");
  VIEW_OWNER.set(view, owner);
}

// Release only the claim held by the caller; a stale disposer cannot release a newer mount.
/** @param {object} view @param {object} owner @returns {void} */
export function releaseView(view, owner) {
  const held = VIEW_OWNER.get(view);
  if (held === undefined) return;
  if (held !== owner) throw new TypeError("view owner does not match");
  VIEW_OWNER.delete(view);
}

// The view tier emits these names, so it declares them and a headless bus refuses them.
events.declare([
  "ui.start",
  "ui.closed",
  "ui.resize",
  "ui.tick",
  "key.press",
  "mouse.input",
  "paste.input",
  "focus.changed",
  "pane.focused",
  "pane.closed",
  "region.focused",
  "clipboard.copied",
  "composer.changed",
  "session.changed",
  "index.changed",
  "activity.changed",
]);

// This table maps a host event type to its core event name.
const HOST_TO_CORE_EVENT = {
  start: "ui.start",
  input_closed: "ui.closed",
  resize: "ui.resize",
  tick: "ui.tick",
  key: "key.press",
  mouse: "mouse.input",
  paste: "paste.input",
  focus: "focus.changed",
};


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

  /** @param {"row" | "col"} kind @param {Node} a @param {Node} b @param {number | undefined} [ratio] @returns {void} */
  becomeSplit(kind, a, b, ratio) {
    if (this.shape.type !== "leaf") throw new TypeError("a split node cannot split again");
    this.shape = { type: "split", kind, a, b, ratio: ratio == null ? 0.5 : ratio };
    a.parent = this;
    b.parent = this;
  }

  // Return the leaf that contains the cell. Return null outside this subtree.
  /** @param {number} col @param {number} row @returns {Node | null} */
  leafAt(col, row) {
    const r = this.rect;
    if (col < r.x || col >= r.x + r.w || row < r.y || row >= r.y + r.h) return null;
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

// --- status bar ---------------------------------------------------------------------------
// One row under the whole layout, where a segment renders to a string or to nothing, so an idle provider takes no space.
export const status = {
  /** @type {StatusEntry[]} */
  _list: [],

  // Register a segment and return a disposer. `side` is "left" or "right"; `order` sorts a side.
  /** @param {StatusSegment} seg @returns {() => void} */
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

  // The text of one side. A segment that renders nothing drops out of the join.
  /** @param {"left" | "right"} which @returns {string} */
  side(which) {
    const out = [];
    for (const seg of this._list) {
      if (seg.side !== which) continue;
      // One bad provider must not take the frame with it.
      /** @type {string | null | undefined} */
      let t = "";
      try {
        t = seg.render();
      } catch (e) {
        events.emit("ext.error", e, "status");
      }
      if (t) out.push(String(t));
    }
    return out.join(" · ");
  },

  // The right side keeps the width it needs, so a long message never pushes it off the row.
  /** @param {Rect} rect @returns {void} */
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
    /** @type {Node | null} */
    this.root_node = null;
    /** @type {Node | null} */
    this.activeLeaf = null;
    /** @type {Overlay[]} */
    this.overlays = [];
    /** @type {TickableEntry[]} */
    this.tickables = [];
    /** @type {Node | null} */
    this._capture = null; // the leaf that owns the drag, from press to release
    /** @type {boolean} */
    this._needsDraw = false; // the host paints once after it drains the event queue
    /** @type {boolean} */
    this._layoutDirty = true;
    /** @type {boolean} */
    this._started = false;
  }

  get active() {
    return this.activeLeaf ? leafView(this.activeLeaf) : null;
  }

  /** @param {Node | null} node @returns {void} */
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

  /** @param {ViewLike | null} view @returns {void} */
  setActive(view) {
    this.setRoot(view == null ? null : Node.leaf(view));
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

  /** @param {Node | null} leaf @returns {void} */
  focusLeaf(leaf) {
    if (leaf && this.root_node && this.root_node.leaves().indexOf(leaf) >= 0) this._setActiveLeaf(leaf);
  }

  // Focus the leaf that holds `view`. Return false when the view is not in the tree.
  /** @param {ViewLike | null} view @returns {boolean} */
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

  // Return the leaf that contains the cell. Return null over a split rule or outside the tree.
  /** @param {number} col @param {number} row @returns {Node | null} */
  leafAt(col, row) {
    return this.root_node ? this.root_node.leafAt(col, row) : null;
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
    const leaf = this.leafAt(ev.col, ev.row);
    if (!leaf) return false;
    if (ev.event === "press" && !isWheel(ev.button)) {
      this.focusLeaf(leaf);
      if (ev.button === "left") this._capture = leaf;
    }
    return !!callHook(leafView(leaf), "onMouse", ev);
  }

  /** @param {"row" | "col"} kind @param {ViewLike} view @returns {Node | null} */
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

  close() {
    const leaf = this.activeLeaf;
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
    this._setActiveLeaf(/** @type {Node} */ (p.leaves()[0]));
    // The tree drops the view here, so the owner learns that its pane left.
    const removed = leafView(leaf);
    releaseView(removed, this);
    events.emit("pane.closed", removed);
    this.invalidate();
  }

  /** @param {"h" | "j" | "k" | "l"} d @returns {void} */
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

  /** @param {number} step @returns {void} */
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

  // Report whether a tickable is registered, so a caller never reads the entry list itself.
  /** @param {Tickable} tickable @returns {boolean} */
  hasTickable(tickable) {
    return this._tickableEntry(tickable) !== undefined;
  }

  // A second registration shares one entry, so one owner cannot stop a service another still holds.
  /** @param {Tickable} tickable @returns {Tickable} */
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

  // Drop one registration. The last one removes the entry, and only a started service gets `onStop`.
  /** @param {Tickable} tickable @returns {void} */
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

  // The widget a nav binding drives, taken from the layer that reads the keyboard.
  /** @returns {NavTarget | null} */
  navTarget() {
    return /** @type {NavTarget | null} */ (callHook(this.focused, "navTarget") || null);
  }

  // The layer that owns the cursor and the nav target: the top modal overlay, else the active view.
  get focused() {
    for (let i = this.overlays.length - 1; i >= 0; i--) {
      const layer = /** @type {Overlay} */ (this.overlays[i]);
      if (layer.modal !== false) return layer;
    }
    return this.active;
  }

  /** @param {Overlay} layer @returns {Overlay} */
  pushOverlay(layer) {
    requireView(layer, "pushOverlay needs layout and draw methods");
    if (this.overlays.indexOf(layer) >= 0) throw new TypeError("an overlay cannot be pushed twice");
    if (this.root_node && this.root_node.leaves().some((leaf) => leafView(leaf) === layer)) throw new TypeError("a root cannot mount a view twice");
    claimView(layer, this);
    this.overlays.push(layer);
    this.invalidate();
    return layer;
  }

  /** @param {Overlay | undefined} layer @returns {void} */
  popOverlay(layer) {
    if (layer) {
      const i = this.overlays.indexOf(layer);
      if (i >= 0) {
        this.overlays.splice(i, 1);
        releaseView(layer, this);
      }
    } else {
      const removed = this.overlays.pop();
      if (removed) releaseView(removed, this);
    }
    this.invalidate();
  }

  // Ask for a frame. The host paints once after the queue drains, so a burst costs one paint.
  /** @returns {void} */
  invalidate() {
    this._needsDraw = true;
    this._layoutDirty = true;
  }

  /** @returns {void} */
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
    if (this.root_node) for (const leaf of this.root_node.leaves()) fn(leafView(leaf), false);
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
    if (barY >= 0) status.draw({ x: 0, y: barY, w: term.width, h: 1 });
    const focused = this.focused;
    for (const layer of this.overlays) {
      callHook(layer, "draw", layer === focused);
    }
    const c = /** @type {{ x: number, y: number, visible: boolean } | null} */ (callHook(this.focused, "cursor"));
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

  /** @returns {void} */
  tickLayers() {
    this._forEachTickable((layer, isTickable) => {
      if (!callHook(layer, "needsTick")) return;
      // A service can remove itself inside `needsTick`, so a stale one must not still get `tick`.
      if (isTickable && !this.hasTickable(/** @type {Tickable} */ (layer))) return;
      callHook(layer, "tick");
    });
  }

  /** @param {RootEvent} ev @returns {void} */
  onEvent(ev) {
    const name = HOST_TO_CORE_EVENT[ev.type];
    if (name) events.emit(name, ev);
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
    // A modal overlay consumes the event even when the overlay has no requested hook.
    const consumedByOverlay = /** @type {(method: string) => boolean} */ ((method) => {
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
    });
    if (ev.type === "key" || ev.type === "paste") {
      if (ev.type === "key" && ev.event === "release") return;
      // A paste completes no sequence, so it ends the wait rather than leaving it armed.
      if (ev.type === "paste" && keymap.owns()) keymap.pending = null;
      if (!consumedByOverlay("onKey")) {
        // The keymap reads a key first while it waits for a sequence, or where a route skips the view.
        const keymapFirst = keymap.owns() || route.reader() === "keymap";
        const viewTakes = !keymapFirst && callHook(this.active, "onKey", ev);
        if (!viewTakes && ev.type === "key") keymap.onKey(ev);
      }
    } else if (ev.type === "mouse") {
      if (!consumedByOverlay("onMouse")) this.routeMouse(ev);
    }
    this.invalidate();
  }
}

export const root = new RootView();

export function quit() {
  term.quit();
}

// A bare key never quits. A stray key in a modal layer must not end the session.
command.add(null, { quit }, { quit: { title: "Quit", description: "leave yuke", slash: "quit" } });

root.addTickable(keymap);

globalThis.onEvent = (ev) => root.onEvent(ev);
globalThis.flushFrame = () => root.flush();
