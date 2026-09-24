// yuke:ext — the plugin runtime: a Scope owns effects and releases, a Context registers, and `advice` wraps methods.
import * as cancellation from "yuke:cancellation-native";
import { events, once } from "yuke:kernel";
import { bindInteraction } from "yuke:interaction";
import { defineTool, removeTool } from "yuke:tools";
import { installDispatcher, installLifecycle, setPoints } from "yuke:hooks";
export { interaction } from "yuke:interaction";

/** @import { AdviceEntry, AdviceFunction, AdviceInfo, AdviceOptions, AdviceRecord, AdviceWhere, Disposer, Effect, EventHandler, EventOptions, HookAnswer, HookDecision, HookEntry, HookHandler, HookPoint, InjectApply, InjectContext, InteractionSurface, Plugin, PluginAsync, PluginHandle, Release, ReleaseEntry, ScopeEntry, ScopeLife, ToolDefinition } from "./types/ext.js" */

const NOOP = () => {};

// --- scope: one owner for sync effects, async-capable releases, a signal, and child scopes ---
export class Scope {
  /** @param {string | undefined} name */
  constructor(name) {
    this.name = name || "scope";
    this.alive = true;
    /** @type {ScopeEntry[]} */
    this._disposers = []; // registration order; reverted in reverse
    /** @type {ScopeEntry | null} */
    this._parentEntry = null;
    /** @type {ScopeLife | null} */
    this._life = null; // made on first use, because each own field costs QuickJS a shape step on a hot constructor
  }

  /** @returns {ScopeLife} */
  _state() {
    return this._life ??= { awaiter: null, releases: null, signal: null, closed: undefined, settle: undefined, draining: null, quiet: false };
  }

  // Report whether this scope or a scope that awaits its close gave up waiting.
  /** @returns {boolean} */
  _quiet() {
    /** @type {Scope | null} */
    let scope = this;
    while (scope) {
      if (scope._life?.quiet) return true;
      scope = scope._life?.awaiter ?? null;
    }
    return false;
  }

  // Run `fn` now. Collect the disposer it returns. The handle reverts this one effect, once.
  /** @param {Effect} fn @returns {Disposer} */
  effect(fn) {
    if (!this.alive) throw new TypeError("effect on a disposed scope: " + this.name);

    const cleanup = fn();
    if (typeof cleanup !== "function") {
      if (cleanup != null && typeof /** @type {any} */ (cleanup).then === "function") {
        Promise.resolve(cleanup).catch(() => {});
        throw new TypeError("scope effects must be synchronous");
      }
      return NOOP;
    }
    // `fn` can dispose this scope re-entrantly, and the sweep already passed. Revert here instead.
    if (!this.alive) {
      cleanup();
      return NOOP;
    }

    const entry = this._addEntry(/** @type {Disposer} */ (cleanup));
    return () => {
      const owner = entry.owner;
      if (owner) owner._runEntry(entry);
    };
  }

  // Hold `release` until this scope closes; a closed scope releases at once and throws.
  /** @param {Release} release @returns {() => void | Promise<void>} */
  own(release) {
    if (typeof release !== "function") throw new TypeError("a resource needs a release function");
    if (!this.alive) {
      this._attempt(release);
      throw new TypeError("the resource owner is closed");
    }
    /** @type {ReleaseEntry} */
    const entry = { release };
    const life = this._state();
    const list = life.releases ??= [];
    list.push(entry);
    return () => {
      const fn = entry.release;
      if (!fn) return;
      entry.release = null;
      const at = list.indexOf(entry);
      if (at >= 0) list.splice(at, 1);
      return this._attempt(fn);
    };
  }

  // The cancellation signal of this scope. A close cancels it before any effect reverts.
  get signal() {
    const life = this._state();
    if (!life.signal) {
      life.signal = cancellation.create();
      if (!this.alive) cancellation.cancel(life.signal);
    }
    return life.signal;
  }

  /** @param {Disposer} cleanup @returns {ScopeEntry} */
  _addEntry(cleanup) {
    /** @type {ScopeEntry} */
    const entry = { owner: this, cleanup, child: null };
    this._disposers.push(entry);
    return entry;
  }

  /** @param {ScopeEntry} entry @returns {void} */
  _runEntry(entry) {
    const cleanup = this._takeEntry(entry);
    if (cleanup) cleanup();
  }

  /** @param {ScopeEntry} entry @returns {Disposer | null} */
  _takeEntry(entry) {
    if (entry.owner !== this) return null;
    entry.owner = null;
    const at = this._disposers.indexOf(entry);
    if (at >= 0) this._disposers.splice(at, 1);
    const cleanup = entry.cleanup;
    entry.cleanup = null;
    return cleanup;
  }

  // A child scope is an effect on this scope, so one LIFO stack owns the whole tree.
  /** @param {string | undefined} name @returns {Scope} */
  child(name) {
    if (!this.alive) throw new TypeError("effect on a disposed scope: " + this.name);
    const s = new Scope(name);
    const parentEntry = this._addEntry(() => { s.dispose(); });
    parentEntry.child = s;
    s._parentEntry = parentEntry;
    return s;
  }

  // Cancel the signal of this scope and of every child, so no effect reverts while its I/O still runs.
  _cancel() {
    const signal = this._life?.signal;
    if (signal) cancellation.cancel(signal);
    for (const entry of this._disposers) if (entry.child) entry.child._cancel();
  }

  // Close newest first: cancel the signals, revert the effects, await the child closes, release, and drain the signal.
  /** @returns {void | Promise<void>} */
  dispose() {
    // A caller inside the close gets the promise the close settles; a finished close answers its own.
    if (!this.alive) return this._life?.closed ?? (closing.has(this) ? this._later() : undefined);
    // The scope is dead before a cancel listener runs, so a listener cannot own a resource here.
    this.alive = false;
    closing.add(this);
    this._cancel();

    const parentEntry = this._parentEntry;
    this._parentEntry = null;
    const parent = parentEntry?.owner ?? null;
    if (parent && parentEntry) parent._takeEntry(parentEntry);

    /** @type {Promise<void>[]} */
    const children = [];
    while (this._disposers.length) {
      const entry = /** @type {ScopeEntry} */ (this._disposers.pop());
      const cleanup = entry.cleanup;
      entry.owner = null;
      entry.cleanup = null;
      if (entry.child) {
        const closed = entry.child.dispose();
        if (closed) {
          children.push(closed);
          entry.child._state().awaiter = this;
        }
        continue;
      }
      try {
        if (cleanup) cleanup();
      } catch (e) {
        // A silent teardown failure hides a plugin bug, so report it on the shared bus.
        events.emit("ext.error", e, this.name);
      }
    }

    // A child that left before this close added its drain here, so read the set after the effects.
    const draining = this._life?.draining;
    if (draining) children.push(...draining);
    const released = children.length ? Promise.all(children).then(() => this._release()) : this._release();
    const signal = this._life?.signal;
    closing.delete(this);
    const later = this._life?.settle;
    if (!released && !signal) {
      later?.();
      return this._life?.closed;
    }
    const closed = Promise.resolve(released).then(() => (signal ? cancellation.drain(signal) : undefined));
    const life = this._state();
    if (later) closed.then(later);
    else life.closed = closed;
    // A child that leaves on its own keeps its parent's close waiting until its releases end.
    if (parent) {
      life.awaiter = parent;
      const set = parent._state().draining ??= new Set();
      set.add(closed);
      closed.then(() => set.delete(closed));
    }
    return life.closed;
  }

  // The promise a caller inside the close receives; the close settles it when it ends.
  /** @returns {Promise<void>} */
  _later() {
    const life = this._state();
    return life.closed ??= new Promise((resolve) => { life.settle = resolve; });
  }

  // Run the held releases newest first; an async release holds the older ones until it settles.
  /** @returns {void | Promise<void>} */
  _release() {
    const list = this._life?.releases;
    while (list?.length) {
      const entry = /** @type {ReleaseEntry} */ (list.pop());
      const fn = entry.release;
      entry.release = null;
      const pending = fn ? this._attempt(fn) : undefined;
      if (pending) return pending.then(() => this._release());
    }
  }

  // Call one release, report its fault, and answer a Promise only for an async release.
  /** @param {Release} fn @returns {Promise<void> | undefined} */
  _attempt(fn) {
    /** @param {unknown} error */
    const report = (error) => { if (!this._quiet()) events.emit("ext.error", error, this.name); };
    try {
      const result = fn();
      if (result != null && typeof /** @type {any} */ (result).then === "function") return Promise.resolve(result).then(NOOP, report);
    } catch (error) {
      report(error);
    }
    return undefined;
  }
}

// The scopes whose close runs now, so a caller inside a close can wait for it without a field on every scope.
/** @type {Set<Scope>} */
const closing = new Set();

// The owner of registrations outside a plugin.
const rootScope = new Scope("root");

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

    rec = { original, descriptor: Object.getOwnPropertyDescriptor(obj, prop), list: [] };
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

  let call = /** @type {AdviceFunction | null} */ (null);
  for (let i = list.length - 1; i >= 0; i--) {
    const entry = /** @type {AdviceEntry} */ (list[i]);
    if (entry.where !== "around") continue;

    const inner = call || /** @type {AdviceFunction} */ ((...as) => Reflect.apply(rec.original, self, as));
    const fn = entry.fn;
    call = (...as) => Reflect.apply(fn, self, [inner, ...as]);
  }

  // Preserve the argument iterator that a filter can supply.
  let result = call ? call(...args) : Reflect.apply(rec.original, self, [...args]);

  for (const a of list) {
    if (a.where !== "filterReturn") continue;
    const next = Reflect.apply(a.fn, self, [result]);
    if (next !== undefined) result = next;
  }
  for (const a of list) if (a.where === "after") Reflect.apply(a.fn, self, args);

  return result;
}

export const advice = {
  // Install one advice, ordered by `order`. The disposer removes only this advice.
  /** @param {object} obj @param {string} prop @param {AdviceWhere} where @param {AdviceFunction} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
  advise(obj, prop, where, fn, opts) {
    if (!Object.hasOwn(WHERE, where)) throw new TypeError("advise: unknown kind " + where);
    if (typeof fn !== "function") throw new TypeError("advise: fn must be a function");

    const owner = (opts && opts.owner) || "anon";
    const name = (opts && opts.name) || fn.name || "advice";
    const order = opts && typeof opts.order === "number" ? opts.order : 0;

    // Build the entry before the record, so a throwing option getter installs no wrapper.
    const entry = { owner, name, where, fn, order };
    const rec = adviceRecord(obj, prop);
    rec.list.push(entry);
    rec.list.sort((a, b) => a.order - b.order);

    return () => {
      const i = rec.list.indexOf(entry);
      if (i < 0) return;
      rec.list.splice(i, 1);
      if (rec.list.length !== 0) return;
      if (rec.descriptor) Object.defineProperty(obj, prop, rec.descriptor);
      else delete /** @type {Record<string, unknown>} */ (obj)[prop];
      const byProp = RECORDS.get(obj);
      if (byProp) delete byProp[prop];
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

    return once(() => {
      const at = list.indexOf(entry);
      if (at < 0) return;
      list.splice(at, 1);
      // Drop the key only while it still holds this list, so a later provide keeps its own.
      if (list.length === 0 && this._map[name] === list) delete this._map[name];
      // Only a withdrawal of the live provider changes what `get` answers.
      if (at === 0) this._changed(name);
    });
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

    return once(() => {
      set.delete(fn);
      if (set.size === 0 && this._watchers[name] === set) delete this._watchers[name];
    });
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
  if (!reserved) reserved = new Set([...Object.getOwnPropertyNames(Context.prototype), "id"]);
  return reserved.has(name);
}

// `inject` holds a block for the capabilities it needs. A change of a named capability rebuilds the child scope of the block.
/** @template {string} K @param {Context} parentContext @param {K[]} names @param {InjectApply<K>} apply @returns {Disposer} */
function injectInto(parentContext, names, apply) {
  const parent = scopeOf(parentContext);
  const id = parentContext.id;
  if (!Array.isArray(names) || names.length === 0) throw new TypeError("inject needs at least one capability name");
  for (const n of names) {
    if (typeof n !== "string" || n === "") throw new TypeError("inject: a capability name must be a non-empty string");
    if (isReserved(n)) throw new TypeError("inject: `" + n + "` is a plugin context member");
  }
  if (typeof apply !== "function") throw new TypeError("inject needs an apply function");
  // One watcher per name, so a name repeated in `names` still builds the block one time per change.
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

    // The injection owns this child scope until its dependencies change.
    const child = parent.child("inject:" + deps.join("+"));
    try {
      const ctx = new Context(child, id);
      // Each build reads the live provider, and a later change builds the block again.
      const bound = /** @type {Record<string, unknown>} */ (/** @type {unknown} */ (ctx));
      for (const n of deps) bound[n] = bindCapability(services.get(n), ctx);
      child.effect(() => apply(/** @type {InjectContext<K>} */ (ctx)));
      // The block can drop its own dependency, so confirm the requirement before the block commits.
      if (satisfied() && !stopped && parent.alive && child.alive) {
        // The old block leaves after the new one registered, so a shared resource passes over without a gap.
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

// --- hooks: the points a plugin answers --- A fact reads as `x.verbed` and needs no answer; a point reads as `x.verb` and the runtime waits.
// Each chain is replaced, never mutated, so a fold walks the chain it started with and copies nothing.
/** @type {Record<string, readonly HookEntry[]>} */
const HOOKS = Object.create(null);

// State which points now hold a handler, so a turn never submits a call no handler wants. The changed point rides along.
/** @param {string} point @returns {void} */
function publishPoints(point) {
  setPoints(Object.keys(HOOKS), point);
}

// Register one handler at the end of its chain. An unknown point throws and registers nothing.
/** @param {string} point @param {string} owner @param {HookHandler<any>} fn @returns {Disposer} */
function addHook(point, owner, fn) {
  const entry = { owner, fn };
  const before = HOOKS[point];
  HOOKS[point] = before ? [...before, entry] : [entry];
  try {
    publishPoints(point);
  } catch (e) {
    if (before) HOOKS[point] = before; else delete HOOKS[point];
    throw e;
  }

  return once(() => {
    const next = /** @type {readonly HookEntry[]} */ (HOOKS[point]).filter((held) => held !== entry);
    if (next.length === 0) delete HOOKS[point]; else HOOKS[point] = next;
    publishPoints(point);
  });
}

// Fold one chain and answer one decision. The runtime calls this, and it never throws.
/** @param {string} point @param {any} payload @returns {Promise<HookDecision | undefined>} */
async function dispatch(point, payload) {
  const list = HOOKS[point];
  if (!list) return undefined;

  let value = payload;
  let replaced = false;
  for (const entry of list) {
    try {
      const result = await entry.fn(value);
      if (result == null) continue;
      const answer = /** @type {HookAnswer} */ (result);
      const block = answer.block;
      if (block !== undefined) return { type: "block", reason: String(block) };
      // Each later handler reads what this one wrote, so a chain composes without a merge rule.
      const replace = answer.replace;
      if (replace !== undefined) {
        value = replace;
        replaced = true;
      }
    } catch (e) {
      // A throwing handler is a plugin bug. The point fails closed, so a broken policy never lets an action through.
      events.emit("ext.error", e, entry.owner);
      return { type: "block", reason: "the " + entry.owner + " plugin failed at " + point };
    }
  }

  return replaced ? { type: "replace", value } : undefined;
}

installDispatcher(dispatch);

// Fold the input hook before native admission; a proposed session has no id yet.
/** @param {string | null} sessionId @param {Wire.Input} input @param {Wire.CreateSession | null} [create] @returns {Promise<Wire.Input>} */
async function prepareInput(sessionId, input, create = null) {
  if (input.type !== "content") return input;
  const decision = await dispatch("input.before", { session_id: sessionId, content: input.content, ...(create ? { create } : {}) });
  if (decision?.type === "block") {
    const error = new Error("an extension stopped the input");
    error.name = "EngineError";
    /** @type {any} */ (error).code = "bad_request";
    throw error;
  }
  return decision?.type === "replace" ? { type: "content", content: decision.value.content } : input;
}

// Every engine request passes here, so no caller reaches native admission with input the hook did not read.
/** @template {keyof Wire.Methods} M @param {M} method @param {Wire.Methods[M]["paramsType"][0]} params @returns {Promise<Wire.Methods[M]["paramsType"][0]>} */
export async function gateInput(method, params) {
  if (method === "session.send_input") {
    const send = /** @type {Wire.SessionSendInputParams} */ (params);
    return { ...send, input: await prepareInput(send.session_id, send.input) };
  }
  if (method === "session.create") {
    const create = /** @type {Wire.CreateSession} */ (params);
    if (create.initial_input == null) return params;
    const { initial_input, ...rest } = create;
    return { ...rest, initial_input: await prepareInput(null, initial_input, rest) };
  }
  return params;
}

// Internal modules read the scope of a context through this function; plugin code cannot import it.
/** @type {(ctx: Context) => Scope} */
export let scopeOf;

// --- plugin context: the register-through-me surface --- Every registration is an effect on the scope, so an unload reverts all of them.
export class Context {
  // The plugin never holds its scope, so it cannot close itself around the registry.
  /** @type {Scope} */
  #scope;

  /** @param {Scope} scope @param {string} id */
  constructor(scope, id) {
    this.#scope = scope;
    this.id = id; // the plugin id; it namespaces commands and owns this plugin's advice
  }

  static {
    scopeOf = (ctx) => ctx.#scope;
  }

  // False once the close starts, so late async work can skip its registrations.
  get alive() {
    return this.#scope.alive;
  }

  // A close cancels this signal before any effect reverts, so I/O started with it aborts.
  get signal() {
    return this.#scope.signal;
  }

  // Hold a resource until the close; its release may be async and runs after the effects revert, newest first.
  /** @param {Release} release @returns {() => void | Promise<void>} */
  own(release) {
    return this.#scope.own(release);
  }

  /** @param {Effect} fn @returns {Disposer} */
  effect(fn) {
    return this.#scope.effect(fn);
  }

  /** @param {string} name @param {EventHandler} fn @param {EventOptions} [opts] @returns {Disposer} */
  on(name, fn, opts) {
    return this.#scope.effect(() => events.on(name, fn, opts));
  }

  /** @param {string} name @param {EventHandler} fn @returns {Disposer} */
  once(name, fn) {
    return this.#scope.effect(() => events.once(name, fn));
  }

  /** @param {object} obj @param {string} prop @param {AdviceWhere} where @param {AdviceFunction} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
  advise(obj, prop, where, fn, opts) {
    return this.#scope.effect(() =>
      advice.advise(obj, prop, where, fn, Object.assign({}, opts, { owner: this.id })),
    );
  }

  /** @param {string} name @param {unknown} value @returns {Disposer} */
  provide(name, value) {
    return this.#scope.effect(() => services.provide(name, value));
  }

  // Answer one point. The chain runs in registration order and this plugin's turn reverts on unload.
  /** @template {HookPoint} P @param {P} point @param {HookHandler<P>} fn @returns {Disposer} */
  hook(point, fn) {
    if (typeof fn !== "function") throw new TypeError("hook needs a handler function");
    return this.#scope.effect(() => addHook(point, this.id, fn));
  }

  // The tools this plugin owns. A dispose withdraws them, so an unload leaves no tool behind.
  get tools() {
    const tools = toolRegistry(this.#scope);
    Object.defineProperty(this, "tools", { value: tools });
    return tools;
  }

  // Run `apply` only while every named capability exists, in a child scope a withdrawal reverts.
  /** @template {string} K @param {K[]} names @param {InjectApply<K>} apply @returns {Disposer} */
  inject(names, apply) {
    return injectInto(this, names, apply);
  }

  // The frontend seam. A service is always installed, so a plugin calls it without `inject`.
  /** @returns {InteractionSurface} */
  get interaction() {
    const surface = bindInteraction(this);
    Object.defineProperty(this, "interaction", { value: surface });
    return surface;
  }
}

// --- plugin registry --- A plugin is `{ name, apply }`; the name keys the registry and prefixes every command, so it is required.
/** @param {Plugin} plugin @returns {void} */
function checkPlugin(plugin) {
  const ok = plugin !== null && typeof plugin === "object" && typeof plugin.apply === "function";
  if (!ok || typeof plugin.name !== "string" || plugin.name === "")
    throw new TypeError("invalid plugin: expected { name, apply }");
}

const readyNow = Promise.resolve();

/** @param {unknown} result */
function checkApplyResult(result) {
  if (result !== undefined) throw new TypeError("plugin apply must return void or Promise<void>");
}

/** @returns {Error} */
function startupCanceled() {
  const error = new Error("plugin startup was canceled");
  error.name = "AbortError";
  return error;
}

// One loaded plugin: its scope, its startup, and the close that holds its name until the scope and the startup settle.
// Only the registry holds an instance; `apply` gets the context and the caller gets a handle.
class PluginInstance {
  /** @param {string} name */
  constructor(name) {
    this.scope = new Scope(name);
    this.context = new Context(this.scope, name);
    this._name = name;
    /** @type {"applying" | "active" | "closing" | "closed"} */
    this._phase = "applying";
    /** @type {PluginAsync | undefined} */
    this._async = undefined; // made only for an async apply or an async close
  }

  get ready() { return this._async?.ready ?? readyNow; }

  /** @returns {PluginAsync} */
  _state() {
    return this._async ??= {};
  }

  /** @param {unknown} error */
  report(error) { events.emit("ext.error", error, this._name); }

  // Close the scope and free the name once the close and any startup settle, or once the deadline gives up.
  /** @returns {void | Promise<void>} */
  dispose() {
    if (this._phase === "closed") return this._async?.closed;
    if (this._phase === "closing") return this._promise();
    const applying = this._phase === "applying";
    this._phase = "closing";
    this._async?.cancelReady?.(startupCanceled());
    const closed = this.scope.dispose();
    // A reentrant dispose can run before apply returns its promise.
    const startup = applying ? readyNow.then(() => this._async?.startup) : this._async?.startup;
    if (!closed && !startup) {
      this._finish();
      return this._async?.closed;
    }
    this._state().timer = setTimeout(() => this._force(), closeTimeoutMs);
    Promise.all([closed, startup?.catch(NOOP)]).then(() => this._finish());
    return this._promise();
  }

  /** @returns {Promise<void>} */
  _promise() {
    const state = this._state();
    return state.closed ??= new Promise((resolve) => { state.settle = resolve; });
  }

  // Give up on a close past its deadline, so a late release fault stays silent and the name is free.
  _force() {
    if (this._phase !== "closing") return;
    this.report(new Error("plugin close timed out"));
    this.scope._state().quiet = true;
    this._finish();
  }

  _finish() {
    if (this._phase === "closed") return;
    this._phase = "closed";
    const state = this._async;
    if (state) {
      if (state.timer !== undefined) clearTimeout(state.timer);
      state.startup = undefined;
      state.cancelReady = undefined;
    }
    if (plugins._live[this._name] === this) delete plugins._live[this._name];
    state?.settle?.();
  }
}

export const plugins = {
  /** @type {Record<string, PluginInstance>} */
  _live: Object.create(null),
  _closing: false,
  /** @type {{ error: unknown } | undefined} */
  _startupFailure: undefined,

  /** @param {Plugin} plugin @returns {PluginHandle} */
  use(plugin) {
    checkPlugin(plugin);
    if (this._closing || !rootScope.alive) throw new TypeError("the plugin registry is closed");
    const name = plugin.name;
    if (this._live[name]) throw new TypeError("plugin `" + name + "` is already in use");
    const instance = new PluginInstance(name);
    this._live[name] = instance;
    try {
      const result = plugin.apply(instance.context);
      if (result != null && typeof /** @type {any} */ (result).then === "function") {
        /** @type {(error: unknown) => void} */
        let rejectReady = NOOP;
        let resolveReady = NOOP;
        const state = instance._state();
        state.ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
        state.ready.catch(NOOP);
        state.cancelReady = rejectReady;
        if (instance._phase !== "applying") rejectReady(startupCanceled());
        state.startup = Promise.resolve(result).then((value) => {
          checkApplyResult(value);
          resolveReady();
        }).catch((error) => {
          rejectReady(error);
          if (instance._phase === "active") {
            this._startupFailure ??= { error };
            instance.report(error);
            instance.dispose();
          }
        }).then(() => {
          state.cancelReady = undefined;
          state.startup = undefined;
        });
      } else {
        checkApplyResult(result);
        if (instance._phase !== "applying") {
          const ready = instance._state().ready = Promise.reject(startupCanceled());
          ready.catch(NOOP);
        }
      }
    } catch (error) {
      if (instance._phase === "applying") instance._phase = "active";
      instance.dispose();
      throw error;
    }
    if (instance._phase === "applying") instance._phase = "active";
    // The handle closes this instance only, so an old handle cannot close a replacement. `ready` is fixed once `use` returns.
    return { ready: instance.ready, dispose: () => instance.dispose() };
  },

  /** @param {string} name @returns {boolean} */
  has(name) { return this._live[name] !== undefined; },

  /** @param {string} name @returns {void | Promise<void>} */
  dispose(name) { return this._live[name]?.dispose(); },

  /** @returns {string[]} */
  names() { return Object.keys(this._live); },

  /** @returns {Promise<void>} */
  _cancelStartup() {
    return Promise.all(Object.values(this._live).filter((entry) => entry._async?.startup || entry._phase === "closing").map((entry) => entry.dispose())).then(NOOP);
  },

  // Report a startup failure once, even after the failed plugin exits.
  /** @returns {void | Promise<void>} */
  ready() {
    const failure = this._startupFailure;
    this._startupFailure = undefined;
    if (failure) return Promise.reject(failure.error);
    const pending = Object.values(this._live).filter((entry) => entry._async?.startup && entry._phase === "active");
    if (!pending.length) return;
    return Promise.all(pending.map((entry) => entry.ready)).then(() => this.ready(), (error) => {
      this._startupFailure = undefined;
      throw error;
    });
  },
};

// Close every plugin newest first under one deadline; a forced pass gives up on the closes that still wait.
const closeTimeoutMs = installLifecycle((force) => {
  plugins._closing = true;
  const entries = Object.values(plugins._live).reverse();
  /** @type {Promise<void>[]} */
  const pending = [];
  for (const entry of entries) {
    const closed = entry.dispose();
    if (force) entry._force();
    else if (closed) pending.push(closed);
  }
  rootScope.dispose();
  return pending.length ? Promise.all(pending).then(NOOP) : undefined;
});

// The scope owns each tool until its disposer runs or the scope closes.
/** @param {Scope} scope */
function toolRegistry(scope) {
  return {
    /** @param {ToolDefinition} definition @returns {Disposer} */
    define(definition) {
      if (definition == null || typeof definition !== "object") {
        throw new TypeError("tools.define expects a tool definition object");
      }
      const name = definition.name;
      return scope.effect(() => {
        defineTool(name, definition);
        return () => removeTool(name);
      });
    },
  };
}
