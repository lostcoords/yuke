// yuke:ext — the plugin runtime: a Scope owns revertible effects, a Context registers, and `advice` wraps methods.
import * as cancellation from "yuke:cancellation-native";
import { events } from "yuke:kernel";
import { bindInteraction } from "yuke:interaction";
export { interaction } from "yuke:interaction";
import { defineTool, removeTool } from "yuke:tools";
import { installDispatcher, installInputGate, installLifecycle, setPoints } from "yuke:hooks";
import { native } from "yuke:engine-native";

/** @import { AdviceEntry, AdviceFunction, AdviceInfo, AdviceOptions, AdviceRecord, AdviceWhere, Disposer, Effect, EventHandler, EventOptions, HookAnswer, HookDecision, HookEntry, HookHandler, HookPoint, InjectApply, InjectContext, InteractionSurface, Plugin, ScopeEntry, ToolDefinition } from "./types/ext.js" */

const NOOP = () => {};

// --- scope: the owner of revertible effects ---
export class Scope {
  /** @param {string | undefined} name */
  constructor(name) {
    this.name = name || "scope";
    this.alive = true;
    /** @type {ScopeEntry[]} */
    this._disposers = []; // registration order; reverted in reverse
    /** @type {ScopeEntry | null} */
    this._parentEntry = null;
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

  /** @param {Disposer} cleanup @returns {ScopeEntry} */
  _addEntry(cleanup) {
    /** @type {ScopeEntry} */
    const entry = { owner: this, cleanup };
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
    const parentEntry = this._addEntry(() => s.dispose());
    s._parentEntry = parentEntry;

    return s;
  }

  // Revert every effect, newest first. A throwing teardown never stops the others.
  /** @returns {void} */
  dispose() {
    if (!this.alive) return;
    this.alive = false;

    const parentEntry = this._parentEntry;
    this._parentEntry = null;
    if (parentEntry) {
      const parent = parentEntry.owner;
      if (parent) parent._takeEntry(parentEntry);
    }

    while (this._disposers.length) {
      const entry = /** @type {ScopeEntry} */ (this._disposers.pop());
      const cleanup = entry.cleanup;
      entry.owner = null;
      entry.cleanup = null;
      try {
        if (cleanup) cleanup();
      } catch (e) {
        // A silent teardown failure hides a plugin bug, so report it on the shared bus.
        events.emit("ext.error", e, this.name);
      }
    }
  }
}

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

// `inject` holds a block for the capabilities it needs. A change of a named capability rebuilds the child scope of the block.
/** @template {string} K @param {Context} parentContext @param {K[]} names @param {InjectApply<K>} apply @returns {Disposer} */
function injectInto(parentContext, names, apply) {
  const { scope: parent, id } = parentContext;
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

    // The injection owns this scope until its dependencies change.
    const child = new Scope("inject:" + deps.join("+"));
    try {
      const ctx = new Context(child, id, parentContext);
      // Each build reads the live provider, and a later change builds the block again.
      const bound = /** @type {Record<string, unknown>} */ (/** @type {unknown} */ (ctx));
      for (const n of deps) bound[n] = bindCapability(services.get(n), ctx);
      child.effect(() => apply(/** @type {InjectContext<K>} */ (ctx)));
      // The block can drop its own dependency, so confirm the requirement before the block commits.
      if (satisfied() && !stopped && parent.alive) {
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

  let done = false;
  return () => {
    if (done) return;
    done = true;
    const next = /** @type {readonly HookEntry[]} */ (HOOKS[point]).filter((held) => held !== entry);
    if (next.length === 0) delete HOOKS[point]; else HOOKS[point] = next;
    publishPoints(point);
  };
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

/** @param {Wire.SessionSendInputParams} params @returns {Promise<Wire.SessionSendInputResult>} */
export async function sendInput(params) {
  const input = await prepareInput(params.session_id, params.input);
  return JSON.parse(await native.request("session.send_input", JSON.stringify({ ...params, input })));
}

/** @param {Wire.CreateSession} params @returns {Promise<Wire.SessionResult>} */
export async function createSession(params) {
  if (params.initial_input != null) {
    const { initial_input, ...create } = params;
    params = { ...create, initial_input: await prepareInput(null, initial_input, create) };
  }
  return JSON.parse(await native.request("session.create", JSON.stringify(params)));
}

// The owner bridge carries both input methods through the same hook policy.
installInputGate((params, method = "session.send_input") => (method === "session.create" ? createSession(params) : sendInput(params)).then(
  (result) => ({ result }),
  (e) => ({ failure: { code: e.code || "internal", message: e.message || String(e) } }),
));

/** @param {Disposer} release */
function releaseResource(release) {
  const result = /** @type {unknown} */ (release());
  if (result != null && typeof /** @type {any} */ (result).then === "function") {
    Promise.resolve(result).catch(NOOP);
    throw new TypeError("resource release must be synchronous");
  }
}

// --- plugin context: the register-through-me surface --- Every registration is an effect on the scope, so an unload reverts all of them.
export class Context {
  /** @param {Scope} scope @param {string} id @param {Context} [parent] */
  constructor(scope, id, parent) {
    this.scope = scope;
    this.id = id; // the plugin id; it namespaces commands and owns this plugin's advice
    if (parent) {
      /** @type {Context | undefined} */
      this._parent = parent;
    }
  }

  get _managed() { return false; }

  /** @returns {import("./types/ext.js").ResourceState} */
  _resources() {
    if (!this._owner) {
      const parent = this._parent?._resources();
      /** @type {import("./types/ext.js").ResourceState | undefined} */
      this._owner = { active: this.scope.alive && (parent?.active ?? true) };
      if (parent) (parent.children ??= new Set()).add(this);
      if (this._managed) plugins._needsStop = true;
      if (!this.scope.alive) this._closeResources();
      else if (!this._managed) this.scope.effect(() => () => { this._closeResources(); });
    }
    return this._owner;
  }

  // Unload cancels this signal before stop runs.
  get signal() {
    const owner = this._resources();
    if (!owner.signal) {
      owner.signal = cancellation.create();
      if (!owner.active) cancellation.cancel(owner.signal);
    }
    return owner.signal;
  }

  // A late resource is released at once; normal release follows stop.
  /** @param {Disposer} release @returns {Disposer} */
  own(release) {
    if (typeof release !== "function") throw new TypeError("a resource needs a release function");
    const owner = this._resources();
    if (!owner.active) {
      releaseResource(release);
      throw new TypeError("the resource owner is closed");
    }
    const resources = owner.resources ??= [];
    const entry = /** @type {import("./types/ext.js").OwnedResource} */ ({ release });
    resources.push(entry);
    return () => {
      const fn = entry.release;
      if (!fn) return;
      entry.release = null;
      const at = resources.indexOf(entry);
      if (at >= 0) resources.splice(at, 1);
      releaseResource(fn);
    };
  }

  _cancelResources() {
    const owner = this._owner;
    if (!owner?.active) return;
    owner.active = false;
    if (owner.signal) cancellation.cancel(owner.signal);
    if (owner.children) for (const child of owner.children) child._cancelResources();
  }

  /** @returns {void | Promise<void>} */
  _closeResources() {
    const owner = this._owner;
    if (!owner) return;
    if (owner.closed) return owner.closed;
    let resolve = NOOP;
    owner.closed = new Promise(done => { resolve = done; });
    this._cancelResources();
    /** @type {Promise<void>[]} */
    const pending = [];
    if (owner.children) for (const child of owner.children) {
      const result = child._closeResources();
      if (result) pending.push(result);
    }
    const resources = owner.resources;
    while (resources?.length) {
      const entry = /** @type {import("./types/ext.js").OwnedResource} */ (resources.pop());
      const release = entry.release;
      entry.release = null;
      try { if (release) releaseResource(release); } catch (error) { events.emit("ext.error", error, this.id); }
    }
    if (owner.signal) pending.push(cancellation.drain(owner.signal));
    Promise.all(pending).then(() => {
      this._parent?._owner?.children?.delete(this);
      this._parent = undefined;
      resolve();
    });
    return owner.closed;
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

  /** @param {object} obj @param {string} prop @param {AdviceWhere} where @param {AdviceFunction} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
  advise(obj, prop, where, fn, opts) {
    return this.scope.effect(() =>
      advice.advise(obj, prop, where, fn, Object.assign({}, opts, { owner: this.id })),
    );
  }

  /** @param {string} name @param {unknown} value @returns {Disposer} */
  provide(name, value) {
    return this.scope.effect(() => services.provide(name, value));
  }

  // Answer one point. The chain runs in registration order and this plugin's turn reverts on unload.
  /** @template {HookPoint} P @param {P} point @param {HookHandler<P>} fn @returns {Disposer} */
  hook(point, fn) {
    if (typeof fn !== "function") throw new TypeError("hook needs a handler function");
    return this.scope.effect(() => addHook(point, this.id, fn));
  }

  // The tools this plugin owns. A dispose withdraws them, so an unload leaves no tool behind.
  get tools() {
    const tools = toolRegistry(this.scope);
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

/** @type {Context | undefined} */
Context.prototype._parent = undefined;
/** @type {import("./types/ext.js").ResourceState | undefined} */
Context.prototype._owner = undefined;

// --- plugin registry --- A plugin is `{ name, apply }`; the name keys the registry and prefixes every command, so it is required.
/** @param {Plugin} plugin @returns {Plugin["stop"]} */
function checkPlugin(plugin) {
  const ok = plugin !== null && typeof plugin === "object" && typeof plugin.apply === "function";
  if (!ok || typeof plugin.name !== "string" || plugin.name === "")
    throw new TypeError("invalid plugin: expected { name, apply }");
  const stop = plugin.stop;
  if (stop !== undefined && typeof stop !== "function")
    throw new TypeError("plugin stop must be a function");
  return stop;
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

/** @typedef {{ stop?: Plugin["stop"], ready?: Promise<void> | undefined, startup?: Promise<void> | undefined, cancelReady?: ((error: Error) => void) | undefined, dispose?: Promise<void> | undefined, force?: (() => void) | undefined }} AsyncPlugin */

class PluginInstance extends Context {
  /** @param {string} name @param {Plugin["stop"]} stop */
  constructor(name, stop) {
    super(new Scope(name), name);
    this._name = name;
    this._phase = "applying";
    if (stop) {
      /** @type {AsyncPlugin | undefined} */
      this._async = { stop };
    }
  }

  get _managed() { return true; }
  get ready() { return this._async?.ready ?? readyNow; }

  /** @param {unknown} error */
  report(error) { events.emit("ext.error", error, this._name); }

  finish() {
    if (this._async) {
      this._async.stop = undefined;
      this._async.force = undefined;
      this._async.cancelReady = undefined;
      this._async.startup = undefined;
    }
    if (plugins._live[this._name] === this) delete plugins._live[this._name];
  }

  /** @returns {void | Promise<void>} */
  dispose() {
    if (this._phase === "stopping") return this._async?.dispose;
    const applying = this._phase === "applying";
    const asynchronous = applying || this._async?.startup || this._async?.stop || this._owner;
    this._phase = "stopping";
    if (!asynchronous) {
      this.scope.dispose();
      if (plugins._live[this._name] === this) delete plugins._live[this._name];
      return;
    }
    const state = this._async ??= {};
    let resolve = NOOP;
    state.dispose = new Promise(done => { resolve = done; });
    state.cancelReady?.(startupCanceled());
    this._cancelResources();
    this.scope.dispose();

    let closed = false;
    /** @type {number | undefined} */
    let timer;
    const close = () => {
      if (closed) return;
      closed = true;
      clearTimeout(timer);
      const drain = this._closeResources();
      if (drain) drain.then(() => { this.finish(); resolve(); });
      else { this.finish(); resolve(); }
    };
    state.force = () => {
      if (!closed) this.report(new Error("plugin stop timed out"));
      close();
    };
    if (!applying && !state.startup && !state.stop) {
      close();
      return state.dispose;
    }
    timer = setTimeout(state.force, stopTimeoutMs);
    /** @type {void | Promise<void>} */
    let stopped = undefined;
    try { const stop = state.stop; stopped = stop?.(this); }
    catch (error) { this.report(error); }
    const stop = Promise.resolve(stopped).catch(error => { if (!closed) this.report(error); });
    // A reentrant dispose can run before apply returns its promise.
    const start = applying ? readyNow.then(() => state.startup) : state.startup ?? readyNow;
    Promise.all([start.catch(() => {}), stop]).then(close);
    return state.dispose;
  }
}

/** @type {AsyncPlugin | undefined} */
PluginInstance.prototype._async = undefined;

export const plugins = {
  /** @type {Record<string, PluginInstance>} */
  _live: Object.create(null),
  _closing: false,
  _needsStop: false,
  /** @type {{ error: unknown } | undefined} */
  _startupFailure: undefined,

  /** @param {Plugin} plugin @returns {import("./types/ext.js").PluginHandle} */
  use(plugin) {
    const stop = checkPlugin(plugin);
    if (this._closing || !rootScope.alive) throw new TypeError("the plugin registry is closed");
    const name = plugin.name;
    if (this._live[name]) throw new TypeError("plugin `" + name + "` is already in use");
    if (stop) this._needsStop = true;
    const instance = new PluginInstance(name, stop);
    this._live[name] = instance;
    try {
      const result = plugin.apply(instance);
      if (result != null && typeof /** @type {any} */ (result).then === "function") {
        this._needsStop = true;
        const state = instance._async ??= {};
        let resolveReady = () => {};
        /** @type {(error: unknown) => void} */
        let rejectReady = () => {};
        state.ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
        state.cancelReady = rejectReady;
        state.ready.catch(() => {});
        if (instance._phase === "stopping") rejectReady(startupCanceled());
        state.startup = Promise.resolve(result).then(value => {
          checkApplyResult(value);
          resolveReady();
        }).catch(error => {
          rejectReady(error);
          if (instance._phase !== "stopping") {
            this._startupFailure ??= { error };
            instance.report(error);
            instance.dispose();
          }
        }).then(() => { state.cancelReady = undefined; state.startup = undefined; });
      } else {
        checkApplyResult(result);
        if (instance._phase === "stopping") {
          const state = instance._async ??= {};
          state.ready = Promise.reject(startupCanceled());
          state.ready.catch(() => {});
        }
      }
    } catch (error) {
      if (instance._phase === "applying") instance._phase = "active";
      instance.dispose();
      throw error;
    }
    if (instance._phase === "applying") instance._phase = "active";
    return instance;
  },

  /** @param {string} name @returns {Scope | undefined} */
  get(name) { return this._live[name]?.scope; },

  /** @param {string} name @returns {void | Promise<void>} */
  dispose(name) { return this._live[name]?.dispose(); },

  /** @returns {string[]} */
  names() { return Object.keys(this._live); },

  /** @returns {Promise<void>} */
  _cancelStartup() {
    return Promise.all(Object.values(this._live).filter(entry => entry._async?.startup || entry._phase === "stopping").map(entry => entry.dispose())).then(() => {});
  },

  // Report a startup failure once, even after the failed plugin exits.
  /** @returns {void | Promise<void>} */
  ready() {
    const failure = this._startupFailure;
    this._startupFailure = undefined;
    if (failure) return Promise.reject(failure.error);
    const pending = Object.values(this._live).filter(entry => entry._async?.startup && entry._phase !== "stopping");
    if (!pending.length) return;
    return Promise.all(pending.map(entry => entry.ready)).then(() => this.ready(), error => {
      this._startupFailure = undefined;
      throw error;
    });
  },
};

const stopTimeoutMs = installLifecycle(force => {
  plugins._closing = true;
  if (!plugins._needsStop && !rootScope.alive) return;
  const entries = Object.values(plugins._live);
  if (!plugins._needsStop) {
    for (let i = entries.length - 1; i >= 0; i--) /** @type {PluginInstance} */ (entries[i]).scope.dispose();
    plugins._live = Object.create(null);
    rootScope.dispose();
    return;
  }
  if (force) {
    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = /** @type {PluginInstance} */ (entries[i]);
      entry.dispose();
      entry._async?.force?.();
    }
    rootScope.dispose();
    return;
  }
  const pending = [];
  for (let i = entries.length - 1; i >= 0; i--) {
    const result = /** @type {PluginInstance} */ (entries[i]).dispose();
    if (result) pending.push(result);
  }
  rootScope.dispose();
  return pending.length ? Promise.all(pending).then(() => {}) : undefined;
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
