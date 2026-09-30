// The frontend-neutral runtime: process configuration and the event bus. A headless frontend loads it, so it never imports `yuke:internal/native/term`.
import { native } from "yuke:internal/native/engine";
import { errorText } from "yuke:internal/format";

/** @typedef {{ copyOnSelect: boolean, scrollLines: number }} MouseConfig */
/** @typedef {{ chordMs: number }} KeymapConfig */
/** @typedef {{ systemPrompt?: string | null, mouse: MouseConfig, keymap: KeymapConfig }} Config */
/** @typedef {{ systemPrompt?: string | null, mouse?: Partial<MouseConfig>, keymap?: Partial<KeymapConfig> }} ConfigPatch */
/** @typedef {(value: unknown) => true | string} ConfigValidator */
/** @typedef {{ [name: string]: ConfigValidator }} ConfigValidators */
/** @typedef {{ [name: string]: Array<(...args: any[]) => unknown> }} ListenerMap */
/** @import { Bus, Notification } from "./types/ext.js" */

// Wrap a disposer so a second call does nothing.
/** @param {() => void} fn @returns {() => void} */
export function once(fn) {
  let done = false;
  return () => {
    if (done) return;
    done = true;
    fn();
  };
}

// A direct write bypasses validation, so use `defineConfig`.
/** The live process configuration. `defineConfig` changes it in place. @type {Config} */
export const config = {
  // A null base selects the built-in prompt for new root sessions.
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

/**
 * Check a config patch and merge it into `config` at once. An absent or undefined field keeps its current value.
 * `systemPrompt` replaces the built-in base prompt, and null keeps the built-in prompt; `${workspace}`, `${session_id}`, and `${agent_name}` in it expand to the session facts.
 * `mouse.scrollLines` is the count of screen lines that one wheel step moves, an integer from 1 to 20 (default 3).
 * `mouse.copyOnSelect` copies the selection when a drag ends (default true).
 * `keymap.chordMs` is the longest wait in milliseconds for the next stroke of a chord, an integer from 1 to 10000 (default 1000).
 * It throws a TypeError for an unknown key or an invalid value, and a throw changes no field.
 * @param {ConfigPatch} partial @returns {ConfigPatch} The same `partial` object.
 */
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
  if (systemPrompt !== undefined) config.systemPrompt = systemPrompt;
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

// The kernel declares only the events that neutral code emits. Each tier declares its own names.
const CORE_EVENTS = new Set(["notify.posted","engine.drained", "engine.activity.changed", "jobs.changed", "interaction.changed", "quit.request", ...native.factNames()]);

// A layer implements only the hooks it needs. Every hook takes at most two arguments, so a call on a frame path allocates no argument list.
/** @param {object | null | undefined} obj @param {string} name @param {unknown} [a] @param {unknown} [b] @returns {unknown} */
export function callHook(obj, name, a, b) {
  const fn = obj && /** @type {Record<string, unknown>} */ (obj)[name];
  return typeof fn === "function" ? fn.call(obj, a, b) : undefined;
}

export class Emitter {
  /** @param {Set<string>} names */
  constructor(names) {
    /** @type {ListenerMap} */
    this._listeners = Object.create(null);
    this._names = names;
    /** @type {((error: unknown, name: string) => void) | null} */
    this.onError = null;
  }

  // Declare more names for the life of a tier, and answer a disposer that withdraws them.
  /** @param {string[]} names @returns {() => void} */
  declare(names) {
    const table = this._names;
    const added = names.filter((n) => !table.has(n));
    for (const n of added) table.add(n);

    return once(() => {
      for (const n of added) table.delete(n);
    });
  }

  // Reject a name a closed bus does not declare, so a typo fails at the call and not in silence.
  /** @param {string} name @returns {void} */
  _check(name) {
    if (this._names.has(name)) return;
    // An `owner:event` name belongs to its owner, so the core set never declares it.
    const at = name.indexOf(":");
    if (at > 0 && at < name.length - 1) return;
    throw new TypeError("unknown event: " + name);
  }

  /** @param {string} name @param {(...args: any[]) => unknown} fn @param {{ prepend?: boolean } | undefined} [opts] @returns {() => void} */
  on(name, fn, opts) {
    this._check(name);
    const list = this._listeners[name];
    // A change replaces the list, so an emit walks a list no listener can change under it.
    this._listeners[name] = !list ? [fn] : opts && opts.prepend ? [fn, ...list] : [...list, fn];
    return () => {
      const held = this._listeners[name];
      const i = held ? held.indexOf(fn) : -1;
      if (!held || i < 0) return;
      if (held.length === 1) delete this._listeners[name];
      else this._listeners[name] = held.slice(0, i).concat(held.slice(i + 1));
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
    const list = this._listeners[name];
    if (!list) return;
    for (const fn of list) {
      try {
        fn(...args);
      } catch (e) {
        this._fault(e, name);
      }
    }
  }

  // Report one listener fault. If `onError` throws, the remaining listeners still run.
  /** @param {unknown} error @param {string} name @returns {void} */
  _fault(error, name) {
    try {
      callHook(this, "onError", error, name);
    } catch (_ignored) {}
  }

  /** @param {string} name @param {...any} args @returns {unknown} */
  bail(name, ...args) {
    this._check(name);
    const list = this._listeners[name];
    if (!list) return undefined;
    // The newest listener answers first, so a later plugin overrides an earlier one.
    for (let i = list.length - 1; i >= 0; i--) {
      let r;
      // A listener that throws claims nothing, so the next listener gets the event.
      try {
        r = /** @type {(...args: any[]) => unknown} */ (list[i])(...args);
      } catch (e) {
        this._fault(e, name);
        continue;
      }
      if (r != null && r !== false) return r;
    }
    return undefined;
  }
}

// The shared bus has the typed surface; the Emitter class stays untyped, so a private bus needs no event map.
/** The process event bus. A listener fault enters the notification history, and the other listeners still run. Prefer `ctx.on`, because an unload of the plugin removes its listener. */
export const events = /** @type {Bus} */ (/** @type {unknown} */ (new Emitter(CORE_EVENTS)));

// The native drains engine events on the owner. The digest coalesces, so a fact says that it happened and never how many times.
native.setEventSink((ev) => {
  if (ev.type === "activity") {
    events.emit("engine.activity.changed");
    return;
  }
  for (const fact of ev.facts) events.emit(fact, ev);
  events.emit("engine.drained", ev);
});

// The history keeps the newest notifications in memory until the process exits.
const NOTIFY_HISTORY = 100;
// Limits on the message, the stack, and the source keep each history entry bounded.
const NOTIFY_TEXT_MAX = 1024;

// A cut never splits a surrogate pair, so a capped text stays well-formed.
/** @param {string} text @returns {string} */
function capText(text) {
  if (text.length <= NOTIFY_TEXT_MAX) return text;
  let end = NOTIFY_TEXT_MAX - 1;
  const unit = text.charCodeAt(end - 1);
  if (unit >= 0xd800 && unit <= 0xdbff) end--;
  return text.slice(0, end) + "…";
}

/** The notifications of this process, oldest first. A repeat of the newest entry increases its count. */
/** @type {Notification[]} */
export const notifications = [];

// True while `notify.posted` runs. A notification from a listener then only enters the history, so a listener never recurses.
let posting = false;

/** Add one notification. `source` names the plugin or the application part that sent it. A frontend displays the entry. */
/** @param {Wire.NoticeLevel} level @param {string} message @param {string} source @param {string} [stack] @returns {void} */
export function notify(level, message, source, stack = "") {
  const text = capText(message);
  const from = capText(source);
  const trace = capText(stack);
  // The process log keeps every notification, a repeat included, in every mode.
  native.log(level, from, text);
  const last = notifications[notifications.length - 1];
  /** @type {Notification} */
  let entry;
  if (last && last.level === level && last.source === from && last.message === text && last.stack === trace) {
    entry = last;
    entry.count++;
  } else {
    entry = { level, source: from, message: text, stack: trace, count: 1 };
    notifications.push(entry);
    if (notifications.length > NOTIFY_HISTORY) notifications.shift();
  }
  if (posting) return;
  posting = true;
  try {
    events.emit("notify.posted", entry);
  } finally {
    posting = false;
  }
}

/**
 * The values as one line: a string as it is, an error as its message, and any other value as JSON, or as its string form when it has no JSON form.
 * @param {readonly unknown[]} values @returns {string}
 */
export function printText(values) {
  let out = "";
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    let text;
    if (typeof value === "string") text = value;
    else if (value instanceof Error) text = errorText(value);
    else {
      try {
        text = JSON.stringify(value) ?? String(value);
      } catch {
        // A cycle or a BigInt has no JSON form.
        text = String(value);
      }
    }
    out += i === 0 ? text : " " + text;
  }
  return out;
}

/** @param {Wire.NoticeLevel} level @returns {(...values: unknown[]) => void} */
const consoleAt = (level) => (...values) => notify(level, printText(values), "console");
// A profile prints the way a script does, and each line enters the one notification channel.
globalThis.print = consoleAt("debug");
globalThis.console = { log: consoleAt("debug"), debug: consoleAt("debug"), info: consoleAt("info"), warn: consoleAt("warn"), error: consoleAt("error") };

/** Report a thrown value as an error notification. The report never throws, because a value can fail every read. */
/** @param {unknown} error @param {string} source @returns {void} */
export function fault(error, source) {
  let message = "a thrown value that has no readable text";
  let stack = "";
  try {
    message = errorText(error);
    if (error instanceof Error && typeof error.stack === "string") stack = error.stack;
  } catch {}
  notify("error", message, source, stack);
}

// A listener fault enters the history like every other fault.
events.onError = fault;

// A script fault that JavaScript cannot catch, such as an interrupt or a startup timeout, enters the history through the host.
native.setFaultSink((source, text) => notify("error", text, source));
