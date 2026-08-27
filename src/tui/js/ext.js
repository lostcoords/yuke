// yuke:ext — the plugin runtime. A Scope owns revertible effects, a Context is the plugin's
// registration surface, `advice` wraps methods, and `plugins` loads and unloads.
import { command, keymap, events } from "yuke:core";

const NOOP = () => {};

// --- scope: the owner of revertible effects ---
export class Scope {
  constructor(name) {
    this.name = name || "scope";
    this.alive = true;
    this._disposers = []; // registration order; reverted in reverse
  }

  // Run `fn` now. Collect the disposer it returns. The handle reverts this one effect, once.
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
  child(name) {
    const s = new Scope(name);
    this.effect(() => () => s.dispose());

    return s;
  }

  // Revert every effect, newest first. A throwing teardown never stops the others.
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

const RECORDS = new WeakMap(); // obj -> { [prop]: { original, list } }

function adviceRecord(obj, prop) {
  let byProp = RECORDS.get(obj);
  if (!byProp) {
    byProp = Object.create(null);
    RECORDS.set(obj, byProp);
  }

  let rec = byProp[prop];
  if (!rec) {
    // An accessor is not a method. Assigning the wrapper would call its setter.
    const desc = findDescriptor(obj, prop);
    if (desc && !("value" in desc)) throw new TypeError("advise: " + prop + " is an accessor");

    const original = obj[prop];
    if (typeof original !== "function") throw new Error("advise: " + prop + " is not a method");

    rec = { original, list: [] };
    obj[prop] = function (...args) {
      return applyAdvice(rec, this, args);
    };
    byProp[prop] = rec;
  }

  return rec;
}

// Find the property descriptor on `obj` or the first prototype that owns it.
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
function applyAdvice(rec, self, args) {
  const list = rec.list;

  for (const a of list) if (a.where === "filterArgs") args = Reflect.apply(a.fn, self, [args]) || args;
  for (const a of list) if (a.where === "before") Reflect.apply(a.fn, self, args);

  let call = (...as) => Reflect.apply(rec.original, self, as);
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i].where !== "around") continue;

    const inner = call;
    const fn = list[i].fn;
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
  list(obj, prop) {
    const byProp = RECORDS.get(obj);
    if (!byProp) return [];

    const out = [];
    for (const p in byProp) {
      if (prop && p !== prop) continue;
      for (const a of byProp[p].list) {
        out.push({ prop: p, owner: a.owner, name: a.name, where: a.where, order: a.order });
      }
    }

    return out;
  },
};

// Put the original method back once no advice remains.
function adviceRestore(obj, prop, rec) {
  obj[prop] = rec.original;
  const byProp = RECORDS.get(obj);
  if (byProp) delete byProp[prop];
}

// --- services: one provider per name ---
export const services = {
  _map: Object.create(null),

  // Register `value` and return a disposer. Both the arrival and the withdrawal emit an event.
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

  get(name) {
    return this._map[name];
  },
};

// --- plugin context: the register-through-me surface ---
// Every registration is an effect on the scope, so an unload reverts all of them.
// A plugin never touches a global registry, which is what makes the unload total.
export class Context {
  constructor(scope, id) {
    this.scope = scope;
    this.id = id; // the plugin id; it namespaces commands and owns this plugin's advice
  }

  effect(fn) {
    return this.scope.effect(fn);
  }

  on(name, fn, opts) {
    return this.scope.effect(() => events.on(name, fn, opts));
  }

  once(name, fn) {
    return this.scope.effect(() => events.once(name, fn));
  }

  // A bare name becomes "<id>:<name>". A name that already holds a ":" stays as the author wrote it.
  command(predicate, map) {
    const scoped = Object.create(null);
    for (const name in map) scoped[this._qualify(name)] = map[name];

    return this.scope.effect(() => command.add(predicate, scoped));
  }

  keymap(bindings, overwrite) {
    return this.scope.effect(() => keymap.add(bindings, overwrite));
  }

  advise(obj, prop, where, fn, opts) {
    return this.scope.effect(() =>
      advice.advise(obj, prop, where, fn, Object.assign({}, opts, { owner: this.id })),
    );
  }

  provide(name, value) {
    return this.scope.effect(() => services.provide(name, value));
  }

  use(name) {
    return services.get(name);
  }

  _qualify(name) {
    return name.indexOf(":") >= 0 ? name : this.id + ":" + name;
  }
}

// --- plugin registry ---
// A plugin is a function `apply(ctx, config)` or an object `{ name, apply }`.
function resolvePlugin(plugin) {
  if (typeof plugin === "function") {
    return { name: plugin.pluginName || plugin.name || "plugin", apply: plugin };
  }
  if (plugin && typeof plugin.apply === "function") {
    return { name: plugin.name || "plugin", apply: plugin.apply };
  }

  throw new TypeError("invalid plugin: expected a function or an object with an apply method");
}

export const plugins = {
  _live: Object.create(null), // name -> Scope

  // Instantiate under a child of `rootScope`. A throw in `apply` reverts the partial scope.
  // `use` by name is idempotent, so a live name disposes first.
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

  get(name) {
    return this._live[name];
  },

  dispose(name) {
    const scope = this._live[name];
    if (!scope) return;

    delete this._live[name];
    scope.dispose();
  },

  names() {
    return Object.keys(this._live);
  },
};
