// yuke:kernel — the frontend-neutral runtime: process configuration and the event bus.
// This module must never import `yuke:term`, because a headless frontend loads it.
import { native } from "yuke:engine-native";

/** @typedef {{ copyOnSelect: boolean, scrollLines: number }} MouseConfig */
/** @typedef {{ chordMs: number }} KeymapConfig */
/** @typedef {{ systemPrompt?: string | null, mouse: MouseConfig, keymap: KeymapConfig }} Config */
/** @typedef {{ systemPrompt?: string | null, mouse?: Partial<MouseConfig>, keymap?: Partial<KeymapConfig> }} ConfigPatch */
/** @typedef {(value: unknown) => true | string} ConfigValidator */
/** @typedef {{ [name: string]: ConfigValidator }} ConfigValidators */
/** @typedef {{ [name: string]: Array<(...args: any[]) => unknown> }} ListenerMap */

// --- config -------------------------------------------------------------------------------
// Runtime configuration. A direct write bypasses validation; use `defineConfig`.
/** @type {Config} */
export const config = {
  // The default prompt applies to sessions that do not provide one, and `null` matches the engine.
  systemPrompt: null,
  // Mouse reporting is always on; `scrollLines` counts screen lines, so a wheel step moves the same in every widget.
  mouse: {
    scrollLines: 3,
    // A drag that ends copies the selection. A release is a deliberate end, so it never surprises.
    copyOnSelect: true,
  },
  keymap: {
    // The maximum wait in milliseconds for the next stroke of a chord.
    chordMs: 1000,
  },
};

// Merge a user config and return it for a default export.
/** @param {ConfigPatch} partial @returns {ConfigPatch} */
export function defineConfig(partial) {
  if (partial == null || typeof partial !== "object" || Array.isArray(partial)) {
    throw new TypeError("defineConfig expects a config object");
  }
  for (const key of Object.keys(partial)) {
    if (key !== "systemPrompt" && key !== "mouse" && key !== "keymap") {
      throw new TypeError("defineConfig: unknown key " + key);
    }
  }
  const systemPrompt = partial.systemPrompt;
  if (systemPrompt !== undefined && systemPrompt !== null && typeof systemPrompt !== "string") {
    throw new TypeError("defineConfig.systemPrompt must be a string or null");
  }
  const mouse = partial.mouse;
  const nextMouse = { ...config.mouse };
  if (mouse !== undefined) applyConfigPatch(nextMouse, MOUSE_FIELDS, /** @type {Record<string, unknown>} */ (mouse), "mouse");
  const km = partial.keymap;
  const nextKeymap = { ...config.keymap };
  if (km !== undefined) applyConfigPatch(nextKeymap, KEYMAP_FIELDS, /** @type {Record<string, unknown>} */ (km), "keymap");
  if (systemPrompt !== undefined) {
    native.setDefaultSystemPrompt(systemPrompt);
    config.systemPrompt = systemPrompt;
  }
  Object.assign(config.mouse, nextMouse);
  Object.assign(config.keymap, nextKeymap);
  return partial;
}

/** @type {ConfigValidators} */
const MOUSE_FIELDS = {
  copyOnSelect: (v) => typeof v === "boolean" || "mouse.copyOnSelect must be a boolean",
  scrollLines: (v) => {
    const scrollLines = /** @type {number} */ (v);
    return (Number.isInteger(scrollLines) && scrollLines >= 1 && scrollLines <= 20) || "mouse.scrollLines must be an integer 1..20";
  },
};

/** @type {ConfigValidators} */
const KEYMAP_FIELDS = {
  chordMs: (v) => {
    const chordMs = /** @type {number} */ (v);
    return (Number.isInteger(chordMs) && chordMs >= 1 && chordMs <= 10000) || "keymap.chordMs must be an integer 1..10000";
  },
};

/** @param {Record<string, unknown>} section @param {ConfigValidators} fields @param {Record<string, unknown>} src @param {string} label */
function applyConfigPatch(section, fields, src, label) {
  if (src == null || typeof src !== "object" || Array.isArray(src)) {
    throw new TypeError("defineConfig." + label + " expects an object");
  }
  /** @type {Record<string, unknown>} */
  const patch = {};
  for (const key of Object.keys(src)) {
    if (!Object.prototype.hasOwnProperty.call(fields, key)) {
      throw new TypeError("defineConfig." + label + ": unknown key " + key);
    }
    if (src[key] === undefined) continue;
    const ok = /** @type {ConfigValidator} */ (fields[key])(src[key]);
    if (ok !== true) throw new TypeError(ok);
    patch[key] = src[key];
  }
  Object.assign(section, patch);
}

// The kernel declares only what neutral code emits, so each tier declares its own names.
// `engine.drained` carries one whole digest; the engine names the rest, so no list can drift.
const CORE_EVENTS = new Set(["ext.error", "engine.drained", ...native.factNames()]);

// True for an `owner:event` name. A plugin owns such a name, so no declaration can enumerate it.
/** @param {string} name @returns {boolean} */
function isNamespaced(name) {
  const at = name.indexOf(":");
  return at > 0 && at < name.length - 1;
}

// A layer implements only the hooks it needs.
/** @param {object | null | undefined} obj @param {string} name @param {...unknown} args @returns {unknown} */
export function callHook(obj, name, ...args) {
  const fn = obj && /** @type {Record<string, unknown>} */ (obj)[name];
  // `Reflect.apply` keeps the receiver even when the hook shadows `Function.prototype.apply`.
  return typeof fn === "function" ? Reflect.apply(fn, obj, args) : undefined;
}

export class Emitter {
  /** @param {Set<string> | null} [names] */
  constructor(names) {
    /** @type {ListenerMap} */
    this._hooks = Object.create(null);
    /** @type {Set<string> | null} */
    this._names = names || null;
    /** @type {((error: unknown, name: string) => void) | null} */
    this.onError = null;
  }

  // Declare more names for the life of a tier, and answer a disposer that withdraws them.
  /** @param {string[]} names @returns {() => void} */
  declare(names) {
    const table = this._names;
    if (!table) return () => {};
    const added = names.filter((n) => !table.has(n));
    for (const n of added) table.add(n);

    let done = false;
    return () => {
      if (done) return;
      done = true;
      for (const n of added) table.delete(n);
    };
  }

  // Reject a name a closed bus does not declare, so a typo fails at the call and not in silence.
  /** @param {string} name @returns {void} */
  _check(name) {
    if (!this._names || this._names.has(name)) return;
    // An `owner:event` name belongs to its owner, so the core set never declares it.
    if (isNamespaced(name)) return;
    throw new TypeError("unknown event: " + name);
  }

  /** @param {string} name @param {(...args: any[]) => unknown} fn @param {{ prepend?: boolean } | undefined} [opts] @returns {() => void} */
  on(name, fn, opts) {
    this._check(name);
    const list = this._hooks[name] || (this._hooks[name] = []);
    if (opts && opts.prepend) list.unshift(fn);
    else list.push(fn);
    return () => {
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    };
  }

  /** @param {string} name @param {(...args: any[]) => unknown} fn @returns {() => void} */
  once(name, fn) {
    const off = this.on(name, (...args) => {
      off();
      return fn(...args);
    });
    return off;
  }

  /** @param {string} name @param {...any} args @returns {void} */
  emit(name, ...args) {
    this._check(name);
    const list = this._hooks[name];
    if (!list) return;
    for (const fn of list.slice()) {
      try {
        fn(...args);
      } catch (e) {
        // If `onError` throws, the remaining listeners still run.
        try {
          callHook(this, "onError", e, name);
        } catch (_ignored) {}
      }
    }
  }

  /** @param {string} name @param {...any} args @returns {unknown} */
  bail(name, ...args) {
    this._check(name);
    const list = this._hooks[name];
    if (!list) return undefined;
    for (const fn of list.slice()) {
      const r = fn(...args);
      if (r != null && r !== false) return r;
    }
    return undefined;
  }
}

export const events = new Emitter(CORE_EVENTS);

// The native drains engine events on the owner, and both tiers read them from here.
// The digest coalesces, so a fact says that it happened and never how many times or with what.
native.setEventSink((ev) => {
  for (const fact of ev.facts) events.emit(fact, ev);
  events.emit("engine.drained", ev);
});

// Report a listener fault where every other fault goes, and never re-enter on the report itself.
events.onError = (error, name) => {
  if (name !== "ext.error") events.emit("ext.error", error, name);
};
