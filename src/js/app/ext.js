// yuke:ext — the plugin runtime: a Scope owns revertible effects, a Context registers, and `advice` wraps methods.
import { events } from "yuke:kernel";

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
/** @typedef {(ctx: Context, config: unknown) => unknown} PluginApply */
/** @typedef {Context & Record<string, any>} InjectContext */
/** @typedef {(ctx: InjectContext) => unknown} InjectApply */
/** @typedef {{ name: string, apply: PluginApply }} Plugin */

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
    if (!this.alive) throw new TypeError("effect on a disposed scope: " + this.name);

    const cleanup = fn();
    if (typeof cleanup !== "function") return NOOP;
    // `fn` can dispose this scope re-entrantly, and the sweep already passed. Revert here instead.
    if (!this.alive) {
      cleanup();
      return NOOP;
    }

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
        events.emit("ext.error", e, this.name);
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
    if (typeof original !== "function") throw new TypeError("advise: " + prop + " is not a method");

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

// Fold the advice around one call: filterArgs, before, around, filterReturn, after, with the first `around` outermost.
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
  // Install one advice, ordered by `order`; the same owner and name replaces in place, so a reload does not stack.
  /** @param {object} obj @param {string} prop @param {AdviceWhere} where @param {AdviceFunction} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
  advise(obj, prop, where, fn, opts) {
    if (!WHERE[where]) throw new TypeError("advise: unknown kind " + where);
    if (typeof fn !== "function") throw new TypeError("advise: fn must be a function");

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
  /** @type {Record<string, Array<{ value: unknown }>>} */
  _map: Object.create(null),
  /** @type {Record<string, Set<() => void>>} */
  _watchers: Object.create(null),

  // Register `value` and return a disposer. A provider stacks, so a withdrawal reveals the one it hid.
  /** @param {string} name @param {unknown} value @returns {Disposer} */
  provide(name, value) {
    if (typeof name !== "string" || name === "") throw new TypeError("provide needs a capability name");
    if (isReserved(name)) throw new TypeError("provide: `" + name + "` is a plugin context member");
    const list = this._map[name] || (this._map[name] = []);
    // The entry identifies the registration, so two providers of one value stay apart.
    const entry = { value };
    list.unshift(entry);
    this._changed(name);

    let done = false;
    return () => {
      if (done) return;
      done = true;
      const at = list.indexOf(entry);
      if (at < 0) return;
      list.splice(at, 1);
      // Drop the key only while it still holds this list, so a later provide keeps its own.
      if (list.length === 0 && this._map[name] === list) delete this._map[name];
      // Only a withdrawal of the live provider changes what `get` answers.
      if (at === 0) this._changed(name);
    };
  },

  /** @param {string} name @returns {unknown} */
  get(name) {
    const top = (this._map[name] || [])[0];
    return top ? top.value : undefined;
  },

  // Report whether a provider holds `name`. A provider of `undefined` still counts as present.
  /** @param {string} name @returns {boolean} */
  has(name) {
    const list = this._map[name];
    return list !== undefined && list.length > 0;
  },

  // Call `fn` after the live provider of `name` changes. `inject` builds and drops its block here.
  /** @param {string} name @param {() => void} fn @returns {Disposer} */
  watch(name, fn) {
    const set = this._watchers[name] || (this._watchers[name] = new Set());
    set.add(fn);

    let done = false;
    return () => {
      if (done) return;
      done = true;
      set.delete(fn);
      if (set.size === 0 && this._watchers[name] === set) delete this._watchers[name];
    };
  },

  // Announce one change of the live provider. A watcher reacts first, so an observer reads a settled registry.
  /** @param {string} name @returns {void} */
  _changed(name) {
    const set = this._watchers[name];
    // A watcher can add or drop a watcher, so this loop reads a copy of the set.
    if (set) {
      for (const fn of Array.from(set)) {
        try {
          fn();
        } catch (e) {
          events.emit("ext.error", e, "service:" + name);
        }
      }
    }
    // Read the provider again, because a watcher can have replaced it since this change started.
    events.emit("service:" + name, this.get(name));
  },
};

// The passes one `inject` build takes before the runtime calls the dependency set unsettled.
const inject_max_passes = 8;

// A capability that registers effects answers `bindTo`, so the block it serves owns what it adds.
/** @param {unknown} value @param {Context} ctx @returns {unknown} */
function bindCapability(value, ctx) {
  const binder = /** @type {{ bindTo?: (ctx: Context) => unknown }} */ (value);
  return value != null && typeof binder.bindTo === "function" ? binder.bindTo(ctx) : value;
}

// A block reads a capability as `ctx.<name>`, so a name that shadows a Context member is refused.
/** @type {Set<string> | null} */
let reserved = null;

// Build the reserved set on first use, because `Context` is declared after this function.
/** @param {string} name @returns {boolean} */
function isReserved(name) {
  if (!reserved) reserved = new Set([...Object.getOwnPropertyNames(Context.prototype), "scope", "id"]);
  return reserved.has(name);
}

// --- inject: hold a block for the capabilities it needs ---
// The block owns a child scope, and a change of a named capability drops that scope and builds it again.
/** @param {Scope} parent @param {string} id @param {string[]} names @param {InjectApply} apply @returns {Disposer} */
function injectInto(parent, id, names, apply) {
  if (!Array.isArray(names) || names.length === 0) throw new TypeError("inject needs at least one capability name");
  for (const n of names) {
    if (typeof n !== "string" || n === "") throw new TypeError("inject: a capability name must be a non-empty string");
    if (isReserved(n)) throw new TypeError("inject: `" + n + "` is a plugin context member");
  }
  if (typeof apply !== "function") throw new TypeError("inject needs an apply function");
  // One watcher per name is enough, because a repeated name builds the block twice for one change.
  const deps = Array.from(new Set(names));

  /** @type {Scope | null} */
  let live = null;
  let building = false;
  let stopped = false;
  let dirty = false;

  const satisfied = () => deps.every((n) => services.has(n));

  const drop = () => {
    const held = live;
    live = null;
    if (held) held.dispose();
  };

  // Build the block once. Answer false when a retry must not follow.
  /** @returns {boolean} */
  const buildOnce = () => {
    if (!satisfied()) {
      drop();
      return false;
    }

    // A bare Scope, not `parent.child()`: a child pushes one disposer per build and never drops it.
    const child = new Scope("inject:" + deps.join("+"));
    try {
      const ctx = new Context(child, id);
      // Each build reads the live provider, and a later change builds the block again.
      const bound = /** @type {Record<string, unknown>} */ (/** @type {unknown} */ (ctx));
      for (const n of deps) bound[n] = bindCapability(services.get(n), ctx);
      child.effect(() => apply(ctx));
      // The block can drop its own dependency, so confirm the requirement before the block commits.
      if (satisfied() && !stopped && parent.alive) {
        // The old block leaves only after the new one holds what it registered, so a shared
        // resource such as an overlay passes from one block to the next without a gap.
        drop();
        live = child;
      } else {
        child.dispose();
        drop();
      }
      return true;
    } catch (e) {
      child.dispose();
      drop();
      // A throwing block keeps its plugin alive, so the runtime reports the fault and stays inactive.
      events.emit("ext.error", e, id);
      return false;
    }
  };

  const build = () => {
    // One change can dispose this injection while a copied watcher list still holds `build`.
    if (stopped || !parent.alive) return;
    // A change during a build must not vanish, so record it and build again after this pass.
    if (building) {
      dirty = true;
      return;
    }

    building = true;
    try {
      var passes = 0;
      do {
        dirty = false;
        if (!buildOnce()) break;
        passes += 1;
      } while (dirty && passes < inject_max_passes && !stopped && parent.alive);
      // A block that changes its own dependency every pass never settles, so report it once.
      if (dirty) events.emit("ext.error", new Error("inject: `" + deps.join("+") + "` does not settle"), id);
    } finally {
      building = false;
      dirty = false;
    }
  };

  // The parent owns the watchers and the effects of the last build.
  return parent.effect(() => {
    const unwatch = deps.map((n) => services.watch(n, build));
    build();
    return () => {
      stopped = true;
      for (const off of unwatch) off();
      drop();
    };
  });
}

// --- plugin context: the register-through-me surface ---
// Every registration is an effect on the scope, so an unload reverts all of them.
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

  // Run `apply` only while every named capability exists, in a child scope a withdrawal reverts.
  /** @param {string[]} names @param {InjectApply} apply @returns {Disposer} */
  inject(names, apply) {
    return injectInto(this.scope, this.id, names, apply);
  }
}

// --- plugin registry ---
// A plugin is `{ name, apply }`. The name keys the registry and prefixes every command, so it is required.
/** @param {Plugin} plugin @returns {void} */
function checkPlugin(plugin) {
  const ok = plugin !== null && typeof plugin === "object" && typeof plugin.apply === "function";
  if (!ok || typeof plugin.name !== "string" || plugin.name === "")
    throw new TypeError("invalid plugin: expected { name, apply }");
}

export const plugins = {
  /** @type {Record<string, Scope>} */
  _live: Object.create(null), // name -> Scope

  // Instantiate under a child of `rootScope`, where a throw in `apply` reverts the partial scope.
  /** @param {Plugin} plugin @param {unknown} [config] @returns {Disposer} */
  use(plugin, config) {
    checkPlugin(plugin);
    const name = plugin.name;
    if (this._live[name]) this.dispose(name);

    const scope = rootScope.child("plugin:" + name);
    const ctx = new Context(scope, name);
    try {
      scope.effect(() => plugin.apply(ctx, config));
    } catch (e) {
      scope.dispose();
      throw e;
    }

    this._live[name] = scope;

    // The disposer clears the slot only while current, so a stale handle cannot evict a reload.
    return () => {
      if (this._live[name] === scope) delete this._live[name];
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
