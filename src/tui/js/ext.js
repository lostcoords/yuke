// yuke:ext — the plugin runtime. A Scope owns revertible effects, a Context is the plugin's
// registration surface, `advice` wraps methods, and `plugins` loads and unloads.
import { command, keymap, events, status } from "yuke:core";

/** @typedef {() => void} Disposer */
/** @typedef {() => unknown} Effect */
/** @typedef {(...args: any[]) => any} AdviceFunction */
/** @typedef {"before" | "after" | "around" | "filterArgs" | "filterReturn"} AdviceWhere */
/** @typedef {{ owner?: string, name?: string, order?: number }} AdviceOptions */
/** @typedef {{ original: AdviceFunction, list: AdviceEntry[] }} AdviceRecord */
/** @typedef {{ owner: string, name: string, key: string, where: AdviceWhere, fn: AdviceFunction, order: number }} AdviceEntry */
/** @typedef {{ prop: string, owner: string, name: string, where: AdviceWhere, order: number }} AdviceInfo */
/** @typedef {Parameters<typeof events.on>[1]} EventHandler */
/** @typedef {Parameters<typeof events.on>[2]} EventOptions */
/** @typedef {Parameters<typeof command.add>[0]} CommandPredicate */
/** @typedef {Parameters<typeof command.add>[1]} CommandMap */
/** @typedef {Parameters<typeof keymap.add>[0]} KeyBindings */
/** @typedef {Parameters<typeof status.add>[0]} StatusSegment */
/** @typedef {(ctx: Context, config: unknown) => unknown} PluginApply */
/** @typedef {PluginApply & { pluginName?: string }} PluginFunction */
/** @typedef {{ name?: string, apply: PluginApply }} PluginObject */
/** @typedef {PluginFunction | PluginObject} Plugin */
/** @typedef {{ name: string, apply: PluginApply }} PluginDefinition */

const NOOP = () => {};

// --- scope: the owner of revertible effects ---
export class Scope {
  /** @param {string | undefined} name */
  constructor(name) {
    this.name = name || "scope";
    this.alive = true;
    /** @type {Disposer[]} */
    this._disposers = []; // registration order; reverted in reverse
  }

  // Run `fn` now. Collect the disposer it returns. The handle reverts this one effect, once.
  /** @param {Effect} fn @returns {Disposer} */
  effect(fn) {
    if (!this.alive) throw new Error("effect on a disposed scope: " + this.name);

    const cleanup = fn();
    if (typeof cleanup !== "function") return NOOP;

    let done = false;
    const entry = () => {
      if (done) return;
      done = true;
      cleanup();
    };
    this._disposers.push(entry);

    return entry;
  }

  // A child scope is an effect on this scope, so one LIFO stack owns the whole tree.
  /** @param {string | undefined} name @returns {Scope} */
  child(name) {
    const s = new Scope(name);
    this.effect(() => () => s.dispose());

    return s;
  }

  // Revert every effect, newest first. A throwing teardown never stops the others.
  /** @returns {void} */
  dispose() {
    if (!this.alive) return;
    this.alive = false;

    for (const d of this._disposers.splice(0).reverse()) {
      try {
        d();
      } catch (e) {
        // A silent teardown failure hides a plugin bug, so report it on the shared bus.
        events.emit("ext:error", e, this.name);
      }
    }
  }
}

// The parent of every plugin scope. A dispose here tears the whole tier down.
export const rootScope = new Scope("root");

// --- advice: named, removable method wrapping ---
const WHERE = { before: 1, after: 1, around: 1, filterArgs: 1, filterReturn: 1 };

/** @type {WeakMap<object, Record<string, AdviceRecord>>} */
const RECORDS = new WeakMap(); // obj -> { [prop]: { original, list } }

/** @param {object} obj @param {string} prop @returns {AdviceRecord} */
function adviceRecord(obj, prop) {
  let byProp = RECORDS.get(obj);
  if (!byProp) {
    byProp = /** @type {Record<string, AdviceRecord>} */ (Object.create(null));
    RECORDS.set(obj, byProp);
  }

  let rec = byProp[prop];
  if (!rec) {
    // An accessor is not a method. Assigning the wrapper would call its setter.
    const desc = findDescriptor(obj, prop);
    if (desc && !("value" in desc)) throw new TypeError("advise: " + prop + " is an accessor");

    const properties = /** @type {Record<string, unknown>} */ (obj);
    const original = /** @type {AdviceFunction} */ (properties[prop]);
    if (typeof original !== "function") throw new Error("advise: " + prop + " is not a method");

    rec = { original, list: [] };
    const record = rec;
    properties[prop] = /** @this {object} @param {...unknown} args */ function (...args) {
      return applyAdvice(record, this, args);
    };
    byProp[prop] = rec;
  }

  return rec;
}

// Find the property descriptor on `obj` or the first prototype that owns it.
/** @param {object} obj @param {string} prop @returns {PropertyDescriptor | undefined} */
function findDescriptor(obj, prop) {
  let holder = obj;
  while (holder) {
    const desc = Object.getOwnPropertyDescriptor(holder, prop);
    if (desc) return desc;
    holder = Object.getPrototypeOf(holder);
  }
  return undefined;
}

// Fold the advice around one call: filterArgs, before, the around chain, filterReturn, after.
// The first-listed `around` is outermost, so the chain wraps in reverse.
/** @param {AdviceRecord} rec @param {object} self @param {any[]} args @returns {any} */
function applyAdvice(rec, self, args) {
  const list = rec.list;

  for (const a of list) if (a.where === "filterArgs") args = Reflect.apply(a.fn, self, [args]) || args;
  for (const a of list) if (a.where === "before") Reflect.apply(a.fn, self, args);

  let call = /** @type {AdviceFunction} */ ((...as) => Reflect.apply(rec.original, self, as));
  for (let i = list.length - 1; i >= 0; i--) {
    const entry = /** @type {AdviceEntry} */ (list[i]);
    if (entry.where !== "around") continue;

    const inner = call;
    const fn = entry.fn;
    call = (...as) => Reflect.apply(fn, self, [inner, ...as]);
  }

  let result = call(...args);

  for (const a of list) if (a.where === "filterReturn") result = Reflect.apply(a.fn, self, [result]);
  for (const a of list) if (a.where === "after") Reflect.apply(a.fn, self, args);

  return result;
}

export const advice = {
  // Install one advice and return a disposer. The same owner and name replaces in place, so a
  // reload does not stack. Sorted by `order`, which defaults to 0.
  /** @param {object} obj @param {string} prop @param {AdviceWhere} where @param {AdviceFunction} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
  advise(obj, prop, where, fn, opts) {
    if (!WHERE[where]) throw new Error("advise: unknown kind " + where);
    if (typeof fn !== "function") throw new Error("advise: fn must be a function");

    const owner = (opts && opts.owner) || "anon";
    const name = (opts && opts.name) || fn.name || "advice";
    const order = opts && typeof opts.order === "number" ? opts.order : 0;
    const key = owner + "\x00" + name;

    // Build the entry before the record, so a throwing option getter installs no wrapper.
    const entry = { owner, name, key, where, fn, order };
    const rec = adviceRecord(obj, prop);
    const at = rec.list.findIndex((a) => a.key === key);
    if (at >= 0) rec.list[at] = entry;
    else rec.list.push(entry);
    rec.list.sort((a, b) => a.order - b.order);

    return () => {
      const i = rec.list.indexOf(entry);
      if (i >= 0) rec.list.splice(i, 1);
      if (rec.list.length === 0) adviceRestore(obj, prop, rec);
    };
  },

  // The advice installed on a target, for a "what is patched here?" view.
  /** @param {object} obj @param {string | undefined} [prop] @returns {AdviceInfo[]} */
  list(obj, prop) {
    const byProp = RECORDS.get(obj);
    if (!byProp) return [];

    const out = [];
    for (const p in byProp) {
      if (prop && p !== prop) continue;
      const record = /** @type {AdviceRecord} */ (byProp[p]);
      for (const a of record.list) {
        out.push({ prop: p, owner: a.owner, name: a.name, where: a.where, order: a.order });
      }
    }

    return out;
  },
};

// Put the original method back once no advice remains.
/** @param {object} obj @param {string} prop @param {AdviceRecord} rec @returns {void} */
function adviceRestore(obj, prop, rec) {
  /** @type {Record<string, unknown>} */ (obj)[prop] = rec.original;
  const byProp = RECORDS.get(obj);
  if (byProp) delete byProp[prop];
}

// --- services: one provider per name ---
export const services = {
  /** @type {Record<string, unknown>} */
  _map: Object.create(null),

  // Register `value` and return a disposer. Both the arrival and the withdrawal emit an event.
  /** @param {string} name @param {unknown} value @returns {Disposer} */
  provide(name, value) {
    this._map[name] = value;
    events.emit("service:" + name, value);

    return () => {
      if (this._map[name] === value) {
        delete this._map[name];
        events.emit("service:" + name, undefined);
      }
    };
  },

  /** @param {string} name @returns {unknown} */
  get(name) {
    return this._map[name];
  },
};

// --- plugin context: the register-through-me surface ---
// Every registration is an effect on the scope, so an unload reverts all of them.
// A plugin never touches a global registry, which is what makes the unload total.
export class Context {
  /** @param {Scope} scope @param {string} id */
  constructor(scope, id) {
    this.scope = scope;
    this.id = id; // the plugin id; it namespaces commands and owns this plugin's advice
  }

  /** @param {Effect} fn @returns {Disposer} */
  effect(fn) {
    return this.scope.effect(fn);
  }

  /** @param {string} name @param {EventHandler} fn @param {EventOptions} [opts] @returns {Disposer} */
  on(name, fn, opts) {
    return this.scope.effect(() => events.on(name, fn, opts));
  }

  /** @param {string} name @param {EventHandler} fn @returns {Disposer} */
  once(name, fn) {
    return this.scope.effect(() => events.once(name, fn));
  }

  // A bare name becomes "<id>:<name>". A name that already holds a ":" stays as the author wrote it.
  /** @param {CommandPredicate} predicate @param {CommandMap} map @returns {Disposer} */
  command(predicate, map) {
    const scoped = Object.create(null);
    for (const name in map) scoped[this._qualify(name)] = map[name];

    return this.scope.effect(() => command.add(predicate, scoped));
  }

  /** @param {KeyBindings} bindings @param {boolean} [overwrite] @returns {Disposer} */
  keymap(bindings, overwrite) {
    return this.scope.effect(() => keymap.add(bindings, overwrite));
  }

  /** @param {StatusSegment} seg @returns {Disposer} */
  status(seg) {
    return this.scope.effect(() => status.add(seg));
  }

  /** @param {object} obj @param {string} prop @param {string} where @param {AdviceFunction} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
  advise(obj, prop, where, fn, opts) {
    return this.scope.effect(() =>
      advice.advise(obj, prop, /** @type {AdviceWhere} */ (where), fn, Object.assign({}, opts, { owner: this.id })),
    );
  }

  /** @param {string} name @param {unknown} value @returns {Disposer} */
  provide(name, value) {
    return this.scope.effect(() => services.provide(name, value));
  }

  /** @param {string} name @returns {unknown} */
  use(name) {
    return services.get(name);
  }

  /** @param {string} name @returns {string} */
  _qualify(name) {
    return name.indexOf(":") >= 0 ? name : this.id + ":" + name;
  }
}

// --- plugin registry ---
// A plugin is a function `apply(ctx, config)` or an object `{ name, apply }`.
/** @param {Plugin} plugin @returns {PluginDefinition} */
function resolvePlugin(plugin) {
  if (typeof plugin === "function") {
    const fn = /** @type {PluginFunction} */ (plugin);
    return { name: fn.pluginName || fn.name || "plugin", apply: fn };
  }
  if (plugin && typeof plugin.apply === "function") {
    return { name: plugin.name || "plugin", apply: plugin.apply };
  }

  throw new TypeError("invalid plugin: expected a function or an object with an apply method");
}

export const plugins = {
  /** @type {Record<string, Scope>} */
  _live: Object.create(null), // name -> Scope

  // Instantiate under a child of `rootScope`. A throw in `apply` reverts the partial scope.
  // `use` by name is idempotent, so a live name disposes first.
  /** @param {Plugin} plugin @param {unknown} [config] @returns {Disposer} */
  use(plugin, config) {
    const def = resolvePlugin(plugin);
    if (this._live[def.name]) this.dispose(def.name);

    const scope = rootScope.child("plugin:" + def.name);
    const ctx = new Context(scope, def.name);
    try {
      scope.effect(() => def.apply(ctx, config));
    } catch (e) {
      scope.dispose();
      throw e;
    }

    this._live[def.name] = scope;

    // The disposer clears the slot only while current, so a stale handle cannot evict a reload.
    return () => {
      if (this._live[def.name] === scope) delete this._live[def.name];
      scope.dispose();
    };
  },

  /** @param {string} name @returns {Scope | undefined} */
  get(name) {
    return this._live[name];
  },

  /** @param {string} name @returns {void} */
  dispose(name) {
    const scope = this._live[name];
    if (!scope) return;

    delete this._live[name];
    scope.dispose();
  },

  /** @returns {string[]} */
  names() {
    return Object.keys(this._live);
  },
};
