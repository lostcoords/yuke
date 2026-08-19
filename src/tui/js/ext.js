// yuke:ext — the plugin runtime: a Scope owns revertible effects, a Context is the plugin's
// registration surface, `advice` wraps methods, `plugins` loads/unloads. Built on yuke:core.
import { command, keymap, events } from "yuke:core";

// --- scope: owner of revertible effects ---
export class Scope {
  constructor(name) {
    this.name = name || "scope";
    this.alive = true;
    this._disposers = []; // registration order; reverted in reverse
  }

  // Run fn now; if it returns a disposer, collect it. The returned handle reverts just this
  // effect, once.
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

  // A child scope is an effect on this one, so both share a single LIFO stack.
  child(name) {
    const s = new Scope(name);
    this.effect(() => () => s.dispose());

    return s;
  }

  // Revert every effect newest-first. Idempotent; a throwing teardown does not abort the rest.
  dispose() {
    if (!this.alive) return;
    this.alive = false;

    for (const d of this._disposers.splice(0).reverse()) {
      try {
        d();
      } catch (_e) {}
    }
  }
}

const NOOP = () => {};

// The parent of every plugin scope; disposing it tears the whole tier down.
export const rootScope = new Scope("root");

// --- advice: named, removable method wrapping ---
// Wrap a method with named, owned advice instead of reassigning it, so it is removable and
// replace-on-readd. Kinds: before/after observe, around wraps, filterArgs/filterReturn transform.
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

// Fold the advice list around one call: filterArgs, before, the around-chain over the original,
// filterReturn, after. First-listed around is outermost, so wrap in reverse.
function applyAdvice(rec, self, args) {
  const list = rec.list;

  for (const a of list) if (a.where === "filterArgs") args = a.fn.call(self, args) || args;
  for (const a of list) if (a.where === "before") a.fn.apply(self, args);

  let call = (...as) => rec.original.apply(self, as);
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i].where !== "around") continue;

    const inner = call;
    const fn = list[i].fn;
    call = (...as) => fn.call(self, inner, ...as);
  }

  let result = call(...args);

  for (const a of list) if (a.where === "filterReturn") result = a.fn.call(self, result);
  for (const a of list) if (a.where === "after") a.fn.apply(self, args);

  return result;
}

export const advice = {
  // Install one advice; returns a disposer. Re-adding the same (owner,name) on the same target
  // replaces it in place. Sorted by order (default 0), stable within a tier.
  advise(obj, prop, where, fn, opts) {
    if (!WHERE[where]) throw new Error("advise: unknown kind " + where);
    if (typeof fn !== "function") throw new Error("advise: fn must be a function");

    const rec = adviceRecord(obj, prop);
    const owner = (opts && opts.owner) || "anon";
    const name = (opts && opts.name) || fn.name || "advice";
    const order = opts && typeof opts.order === "number" ? opts.order : 0;
    const key = owner + "\x00" + name;

    const entry = { owner, name, key, where, fn, order };
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

  // The installed advice on a target (all props, or one), for a "what's patched?" view.
  list(obj, prop) {
    const byProp = RECORDS.get(obj);
    if (!byProp) return [];

    const out = [];
    for (const p in byProp) {
      if (prop && p !== prop) continue;
      for (const a of byProp[p].list) out.push({ prop: p, owner: a.owner, name: a.name, where: a.where, order: a.order });
    }

    return out;
  },
};

// Restore the pristine method once nothing advises it.
function adviceRestore(obj, prop, rec) {
  obj[prop] = rec.original;
  const byProp = RECORDS.get(obj);
  if (byProp) delete byProp[prop];
}

// --- services: a minimal registry ---
// provide(name, value) registers a value and returns a disposer that withdraws it, emitting
// "service:<name>" on appear and withdrawal. One provider per name.
export const services = {
  _map: Object.create(null),

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
// A Context wraps a Scope and exposes the owned registration API. Every registration is an effect
// on the scope, so unload is a total revert; plugins never touch the global registries directly.
export class Context {
  constructor(scope, id) {
    this.scope = scope;
    this.id = id; // plugin id; namespaces commands and owns this plugin's advice
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

  // Register commands under one predicate; a bare name is namespaced "<id>:<name>", one already
  // carrying a ":" is left as the author wrote it.
  command(predicate, map) {
    const scoped = Object.create(null);
    for (const name in map) scoped[this._qualify(name)] = map[name];

    return this.scope.effect(() => command.add(predicate, scoped));
  }

  keymap(bindings, overwrite) {
    return this.scope.effect(() => keymap.add(bindings, overwrite));
  }

  advise(obj, prop, where, fn, opts) {
    return this.scope.effect(() => advice.advise(obj, prop, where, fn, Object.assign({}, opts, { owner: this.id })));
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
// A plugin is a function apply(ctx, config) or an object { name, apply }. apply registers through
// the ctx and may return one extra disposer. use() by name is idempotent — a live name disposes first.
function resolvePlugin(plugin) {
  if (typeof plugin === "function") return { name: plugin.pluginName || plugin.name || "plugin", apply: plugin };
  if (plugin && typeof plugin.apply === "function") return { name: plugin.name || "plugin", apply: plugin.apply };

  throw new Error("invalid plugin: expected a function or an object with an apply method");
}

export const plugins = {
  _live: Object.create(null), // name -> Scope

  // Instantiate under a child of rootScope; if apply throws, the partial scope is reverted. The
  // disposer clears the live slot only while still current, so a stale disposer cannot evict a reload.
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
