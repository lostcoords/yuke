// The plugin runtime: a Scope owns effects and releases, a Context registers, and `advice` wraps methods.
import * as cancellation from "yuke:internal/native/cancellation";
import { events, fault, notify, once, printText } from "yuke:internal/kernel";
import { bindInteraction } from "yuke:internal/interaction";
import { defineTool, removeTool } from "yuke:internal/native/tools";
import { installDispatcher, installLifecycle, setPoints } from "yuke:internal/native/hooks";

/** @import { AdviceFor, AdviceFunction, AdviceOptions, AdviceWhere, Disposer, EventName, EventOptions, Events, FreeName, HookAnswer, HookHandler, HookPoint, InjectApply, InjectContext, InteractionSurface, MethodKey, Plugin, PluginHandle, Provider, Release, ToolDefinition } from "./types/ext.js" */
/** @import { AdviceEntry, AdviceInfo, AdviceRecord, HookDecision, HookEntry, PluginAsync, ReleaseEntry, ScopeEntry, ScopeLife } from "./types/runtime.js" */

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
  /** @param {() => unknown} fn @returns {Disposer} */
  effect(fn) {
    if (!this.alive) throw new TypeError("effect on a disposed scope: " + this.name);

    const cleanup = fn();
    if (typeof cleanup !== "function") {
      if (cleanup != null && typeof /** @type {{ then?: unknown }} */ (cleanup).then === "function") {
        Promise.resolve(cleanup).catch(NOOP);
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
    return () => entry.owner?._takeEntry(entry)?.();
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

  /** @param {Disposer | null} cleanup @returns {ScopeEntry} */
  _addEntry(cleanup) {
    /** @type {ScopeEntry} */
    const entry = { owner: this, cleanup, child: null };
    this._disposers.push(entry);
    return entry;
  }

  // Every caller passes an entry this scope still owns.
  /** @param {ScopeEntry} entry @returns {Disposer | null} */
  _takeEntry(entry) {
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
    // The close walks child entries by `child`, so a child entry holds no cleanup.
    const parentEntry = this._addEntry(null);
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
        // A silent teardown failure hides a plugin bug, so report it as a notification.
        fault(e, this.name);
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
    const report = (error) => { if (!this._quiet()) fault(error, this.name); };
    try {
      const result = fn();
      if (result != null && typeof /** @type {{ then?: unknown }} */ (result).then === "function") return Promise.resolve(result).then(NOOP, report);
    } catch (error) {
      report(error);
    }
    return undefined;
  }
}

// The scopes whose close runs now, so a caller inside a close can wait for it without a field on every scope.
/** @type {Set<Scope>} */
const closing = new Set();

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
    let desc;
    for (let holder = obj; holder && !desc; holder = Object.getPrototypeOf(holder)) desc = Object.getOwnPropertyDescriptor(holder, prop);
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
  /** @template {object} T @template {MethodKey<T>} P @template {AdviceWhere} W @param {T} obj @param {P} prop @param {W} where @param {AdviceFor<Extract<T[P], AdviceFunction>, W, T>} fn @param {AdviceOptions | undefined} [opts] @returns {Disposer} */
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
    if (RESERVED.has(name)) throw new TypeError("provide: `" + name + "` is a plugin context member");
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
          fault(e, "service:" + name);
        }
      }
    }
    // Read the provider again, because a watcher can have replaced it since this change started.
    events.emit(/** @type {`service:${string}`} */ ("service:" + name), this.get(name));
  },
};

// The passes one `inject` build takes before the runtime calls the dependency set unsettled.
const inject_max_passes = 8;

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
      fault(e, entry.owner);
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
    Object.assign(error, { code: "bad_request" });
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
/** The registration surface that `apply` of a plugin gets. Each registration is an effect of the plugin, so an unload of the plugin reverts it. */
export class Context {
  // The plugin never holds its scope, so it cannot close itself around the registry.
  /** @type {Scope} */
  #scope;

  /** @param {Scope} scope @param {string} id */
  constructor(scope, id) {
    this.#scope = scope;
    /** The plugin name. It prefixes the commands of the plugin and owns its advice. */
    this.id = id;
  }

  static {
    scopeOf = (ctx) => ctx.#scope;
  }

  /** True until the close of the plugin starts. Async work reads it to skip late registrations. */
  get alive() {
    return this.#scope.alive;
  }

  /** The cancellation signal of the plugin. The close cancels it before any effect reverts, so I/O that holds it aborts. */
  get signal() {
    return this.#scope.signal;
  }

  /**
   * Hold a resource until the plugin closes. The close calls `release` after the effects revert, newest first, and waits for a returned Promise.
   * On a closed plugin, `own` calls `release` at once and throws a TypeError.
   * @param {Release} release @returns {() => void | Promise<void>} A function that releases the resource now, one time.
   */
  own(release) {
    return this.#scope.own(release);
  }

  /**
   * Run `fn` now and keep the cleanup function it returns. The close runs the cleanups newest first.
   * It throws a TypeError on a closed plugin or when `fn` returns a Promise.
   * @param {() => unknown} fn @returns {Disposer} A disposer that runs this cleanup now, one time.
   */
  effect(fn) {
    return this.#scope.effect(fn);
  }

  /**
   * Listen to one bus event until the disposer runs or the plugin unloads.
   * It throws a TypeError for an event name that no tier declares. An `owner:event` name needs no declaration.
   * @template {EventName} K @param {K} name @param {Events[K]} fn @param {EventOptions} [opts] @returns {Disposer}
   */
  on(name, fn, opts) {
    return this.#scope.effect(() => events.on(name, fn, opts));
  }

  /**
   * Listen to the next emit of one bus event only. The disposer or an unload of the plugin removes the listener before that emit.
   * @template {EventName} K @param {K} name @param {Events[K]} fn @returns {Disposer}
   */
  once(name, fn) {
    return this.#scope.effect(() => events.once(name, fn));
  }

  /**
   * Wrap the method `prop` of `obj` with advice until the disposer runs or the plugin unloads.
   * It throws a TypeError when `prop` is an accessor or not a method, or when `where` is unknown.
   * @template {object} T @template {MethodKey<T>} P @template {AdviceWhere} W @param {T} obj @param {P} prop @param {W} where @param {AdviceFor<Extract<T[P], AdviceFunction>, W, T>} fn @param {AdviceOptions | undefined} [opts] - The context sets `owner` to the plugin name.
   * @returns {Disposer} A disposer that removes this advice only. The last removal puts the original method back.
   */
  advise(obj, prop, where, fn, opts) {
    return this.#scope.effect(() =>
      advice.advise(obj, prop, where, fn, Object.assign({}, opts, { owner: this.id })),
    );
  }

  /**
   * Provide the capability `name` until the disposer runs or the plugin unloads. A newer provider hides an older one until the newer one leaves.
   * It throws a TypeError for an empty name or the name of a Context member.
   * @template {string} K @param {K & FreeName<K>} name @param {Provider<K>} value - The capability, or an object whose `bindTo(ctx)` builds one for each `inject` block.
   * @returns {Disposer}
   */
  provide(name, value) {
    return this.#scope.effect(() => services.provide(name, value));
  }

  /**
   * Answer one engine hook point until the disposer runs or the plugin unloads. The handlers of a point run in registration order.
   * A handler that throws blocks the action. It throws a TypeError when `fn` is not a function or the point is unknown.
   * @template {HookPoint} P @param {P} point @param {HookHandler<P>} fn @returns {Disposer}
   */
  hook(point, fn) {
    if (typeof fn !== "function") throw new TypeError("hook needs a handler function");
    return this.#scope.effect(() => addHook(point, this.id, fn));
  }

  /** The tools of this plugin. An unload of the plugin removes each tool it defines. */
  get tools() {
    const scope = this.#scope;
    // The scope owns each tool until its disposer runs or the scope closes.
    const tools = {
      /**
       * Register one tool that the model can call. It throws a TypeError for a name that another tool has, an invalid name,
       * an empty description, parameters without `type: "object"` and a `properties` object, or a missing `execute`.
       * @param {ToolDefinition} definition @returns {Disposer} A disposer that removes the tool.
       */
      define(definition) {
        if (definition == null || typeof definition !== "object") throw new TypeError("tools.define expects a tool definition object");
        const name = definition.name;
        return scope.effect(() => {
          defineTool(name, definition);
          return () => removeTool(name);
        });
      },
    };
    Object.defineProperty(this, "tools", { value: tools });
    return tools;
  }

  // Its close runs as a release of this plugin; a child that closes first drops that release.
  /**
   * Start a child plugin that this plugin owns. The close of this plugin also closes the child.
   * It throws a TypeError for a plugin without `name` and `apply`, or for a name that a live plugin has.
   * @param {Plugin} plugin @returns {PluginHandle}
   */
  use(plugin) {
    const instance = startPlugin(plugin);
    if (instance._phase !== "closed") instance._state().owner = this.#scope.own(() => instance.dispose());
    return { dispose: () => instance.dispose() };
  }

  /**
   * Run `apply` while each named capability has a provider. `apply` reads each capability as `ctx.<name>`.
   * A change of a live provider reverts the block and runs it again. A missing capability reverts it. A fault in `apply` is reported, and the block stays off.
   * It throws a TypeError for an empty list, an empty name, the name of a Context member, or an `apply` that is not a function.
   * @template {string} K @param {(K & FreeName<K>)[]} names @param {InjectApply<K>} apply @returns {Disposer} A disposer that stops the injection and reverts the live block.
   */
  inject(names, apply) {
    const parent = this.#scope;
    const id = this.id;
    if (!Array.isArray(names) || names.length === 0) throw new TypeError("inject needs at least one capability name");
    for (const n of names) {
      if (typeof n !== "string" || n === "") throw new TypeError("inject: a capability name must be a non-empty string");
      if (RESERVED.has(n)) throw new TypeError("inject: `" + n + "` is a plugin context member");
    }
    if (typeof apply !== "function") throw new TypeError("inject needs an apply function");
    // One watcher per name, so a name repeated in `names` still builds the block one time per change.
    const deps = Array.from(new Set(names));

    /** @type {Scope | null} */
    let live = null;
    // The providers the live block bound, so a watcher that reports no new provider builds nothing.
    /** @type {unknown[]} */
    let bound = [];
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
      // A nested provide can report one change to two watchers of this block.
      if (live && deps.every((n, i) => services.get(n) === bound[i])) return false;
      // The old block leaves before the new one starts, so the two never hold a resource at the same time.
      drop();
      // The old cleanup can withdraw a dependency.
      if (!satisfied()) return false;

      // The injection owns this child scope until its dependencies change.
      const child = parent.child("inject:" + deps.join("+"));
      try {
        const ctx = new Context(child, id);
        // Each build reads the live provider, and a later change builds the block again.
        const members = /** @type {Record<string, unknown>} */ (/** @type {unknown} */ (ctx));
        const values = deps.map((n) => services.get(n));
        // A capability that registers effects answers `bindTo`, so the block it serves owns what it adds.
        let i = 0;
        for (const n of deps) {
          const value = /** @type {{ bindTo?: (ctx: Context) => unknown } | null | undefined} */ (values[i++]);
          members[n] = typeof value?.bindTo === "function" ? value.bindTo(ctx) : value;
        }
        child.effect(() => apply(/** @type {InjectContext<K>} */ (ctx)));
        // The block can drop its own dependency, so confirm the requirement before the block commits.
        if (satisfied() && !stopped && parent.alive && child.alive) {
          live = child;
          bound = values;
        } else child.dispose();
        return true;
      } catch (e) {
        child.dispose();
        // A throwing block keeps its plugin alive, so the runtime reports the fault and stays inactive.
        fault(e, id);
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
        if (dirty) notify("error", "inject: `" + deps.join("+") + "` does not settle", id);
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

  /**
   * Post the values as one `debug` notification with this plugin as the source, as the global `print` does. A debug line never toasts.
   * @param {...unknown} values @returns {void}
   */
  print(...values) {
    notify("debug", printText(values), this.id);
  }

  /** Prompts and notifications through the frontend. It needs no `inject`. @returns {InteractionSurface} */
  get interaction() {
    const surface = bindInteraction(this);
    Object.defineProperty(this, "interaction", { value: surface });
    return surface;
  }
}

// A block reads a capability as `ctx.<name>`, so a name that shadows a Context member is refused.
const RESERVED = new Set([...Object.getOwnPropertyNames(Context.prototype), "id"]);

// --- plugin registry --- A plugin is `{ name, apply }`; the name keys the registry and prefixes every command, so it is required.

const readyNow = Promise.resolve();

// One loaded plugin: its scope, its async apply, and the close that holds its name until both settle.
// Only the registry holds an instance; `apply` gets the context and the caller gets a handle.
class PluginInstance {
  /** @param {string} name */
  constructor(name) {
    this.scope = new Scope(name);
    this.context = new Context(this.scope, name);
    this._name = name;
    /** @type {"active" | "closing" | "closed"} */
    this._phase = "active";
    /** @type {PluginAsync | undefined} */
    this._async = undefined; // made only for an async close
    /** @type {Promise<void> | undefined} */
    this._running = undefined; // an async apply until it settles; it never rejects
    this._applying = true; // true while `apply` runs, so a close inside it waits for the promise it returns
  }

  /** @returns {PluginAsync} */
  _state() {
    return this._async ??= {};
  }

  // Close the scope and free the name once the close and the apply settle, or once the deadline gives up.
  /** @returns {void | Promise<void>} */
  dispose() {
    if (this._phase === "closed") return this._async?.closed;
    if (this._phase === "closing") return this._promise();
    this._phase = "closing";
    const closed = this.scope.dispose();
    // A close inside `apply` cannot see its promise yet, so it reads `_running` one job later.
    const running = this._applying ? readyNow.then(() => this._running) : this._running;
    if (!closed && !running) {
      this._finish();
      return this._async?.closed;
    }
    this._state().timer = setTimeout(() => this._force(), closeTimeoutMs);
    Promise.all([closed, running]).then(() => this._finish());
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
    notify("error", "plugin close timed out", this._name);
    this.scope._state().quiet = true;
    this._finish();
  }

  // A failed apply is the plugin's fault. A close cancels the signal, so a rejection after the close stays silent.
  /** @param {unknown} error */
  _fail(error) {
    if (!this.scope.alive) return;
    fault(error, this._name);
    this.dispose();
  }

  _finish() {
    if (this._phase === "closed") return;
    this._phase = "closed";
    const state = this._async;
    if (state?.timer !== undefined) clearTimeout(state.timer);
    if (plugins._live[this._name] === this) delete plugins._live[this._name];
    state?.owner?.();
    state?.settle?.();
  }
}

// Apply `plugin` under its name for `plugins.use` and `ctx.use`. The host never waits for an async apply.
// A failed apply is reported once under the plugin name, and only that plugin closes.
/** @param {Plugin} plugin @returns {PluginInstance} */
function startPlugin(plugin) {
  // A plugin comes from user code, so its shape is checked here.
  if (plugin === null || typeof plugin !== "object" || typeof plugin.apply !== "function" || typeof plugin.name !== "string" || plugin.name === "")
    throw new TypeError("invalid plugin: expected { name, apply }");
  if (plugins._closing) throw new TypeError("the plugin registry is closed");
  const name = plugin.name;
  if (plugins._live[name]) throw new TypeError("plugin `" + name + "` is already in use");
  const instance = new PluginInstance(name);
  plugins._live[name] = instance;
  // The apply, the `then` of its result, and a cleanup on a closed scope run user code. The catch reports each failure.
  try {
    const result = plugin.apply(instance.context);
    instance._applying = false;
    if (result != null && typeof /** @type {{ then?: unknown }} */ (result).then === "function") {
      const running = Promise.resolve(result).then((value) => {
        if (value !== undefined) throw new TypeError("an async plugin apply must resolve to nothing; register cleanup with ctx.own");
      }).catch((error) => instance._fail(error)).then(() => {
        if (instance._running === running) instance._running = undefined;
      });
      instance._running = running;
    } else if (typeof result === "function") {
      // A sync apply may return its cleanup, as an `inject` block does; a closed scope runs it at once.
      if (instance.scope.alive) instance.scope.effect(() => result);
      else result();
    } else if (result !== undefined) throw new TypeError("plugin apply must return nothing, a cleanup function, or a promise");
  } catch (error) {
    instance._applying = false;
    instance._fail(error);
  }
  return instance;
}

/** The process plugin registry. One name holds at most one live plugin. A plugin that closes frees its name. */
export const plugins = {
  /** @type {Record<string, PluginInstance>} */
  _live: Object.create(null),
  _closing: false,

  /**
   * Start a plugin under its name. The host does not wait for an async `apply`, and a rejection reports a fault and closes the plugin.
   * It throws a TypeError for a plugin without `name` and `apply`, for a name that a live plugin has, or after the registry closes.
   * @param {Plugin} plugin @returns {PluginHandle} A handle that closes this instance only.
   */
  use(plugin) {
    const instance = startPlugin(plugin);
    // The handle closes this instance only, so an old handle cannot close a replacement.
    return { dispose: () => instance.dispose() };
  },

  /** Report whether a live plugin has this name. A plugin that still closes counts as live. @param {string} name @returns {boolean} */
  has(name) { return this._live[name] !== undefined; },

  /**
   * Close the live plugin with this name. No live plugin with the name answers undefined.
   * @param {string} name @returns {void | Promise<void>} A Promise while the close waits for async releases or an async apply, else undefined.
   */
  dispose(name) { return this._live[name]?.dispose(); },

  /** The names of the live plugins. @returns {string[]} */
  names() { return Object.keys(this._live); },
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
  return pending.length ? Promise.all(pending).then(NOOP) : undefined;
});
