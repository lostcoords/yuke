// The shared interaction lifecycle owns each request until its answer or cancellation.
import { events } from "yuke:kernel";
import { native } from "yuke:interaction-native";
import * as cancellation from "yuke:cancellation-native";
/** @import { CancellationSignal } from "yuke:cancellation-native" */
/** @import { Context } from "yuke:ext" */
/** @import { Answerer, Disposer, InteractionOptions, InteractionRequest, InteractionSurface } from "./types/ext.js" */

const MAX_SAFE_ID = Number.MAX_SAFE_INTEGER;
let nextId = 1;

// The UTF-8 size of a string. A lone surrogate counts as the three bytes of its replacement.
/** @param {string} text @returns {number} */
export function utf8Length(text) {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) bytes += 1;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else bytes += 3;
  }
  return bytes;
}

/** @param {unknown} value @param {string} name @param {boolean} [empty] @returns {string} */
function text(value, name, empty = false) {
  if (typeof value !== "string") throw new TypeError(name + " must be a string");
  if ((!empty && value.length === 0) || (value.length * 3 > native.maxTextBytes && utf8Length(value) > native.maxTextBytes)) {
    throw new TypeError(name + " has an invalid length");
  }
  return value;
}

/** @param {string} title @param {string} message @returns {{ type: "confirm", title: string, message: string }} */
function confirmRequest(title, message) {
  return { type: "confirm", title: text(title, "confirm title"), message: text(message, "confirm message", true) };
}

/** @param {string} title @param {string[]} options @returns {{ type: "select", title: string, options: string[] }} */
function selectRequest(title, options) {
  title = text(title, "select title");
  if (!Array.isArray(options) || options.length === 0 || options.length > native.maxOptions) {
    throw new TypeError("select options must be a non-empty bounded array");
  }
  const values = options.map((option) => text(option, "select option"));
  if (new Set(values).size !== values.length) throw new TypeError("select options must be unique");
  return { type: "select", title, options: values };
}

/** @param {string} title @param {string | undefined} placeholder @param {boolean} [secret] @returns {{ type: "input", title: string, placeholder?: string, secret?: boolean }} */
function inputRequest(title, placeholder, secret = false) {
  const request = { type: /** @type {const} */ ("input"), title: text(title, "input title") };
  if (placeholder !== undefined) Object.assign(request, { placeholder: text(placeholder, "input placeholder", true) });
  if (secret) Object.assign(request, { secret: true });
  return request;
}

/** @param {unknown} level @returns {"info" | "warn" | "error"} */
function noticeLevel(level) {
  if (level !== "info" && level !== "warn" && level !== "error") throw new TypeError("notify level is invalid");
  return level;
}

// A wrap reuses an id the host may still hold, and the host answers `Duplicate` if it does.
function allocateId() {
  const id = nextId;
  nextId = nextId === MAX_SAFE_ID ? 1 : nextId + 1;
  return id;
}

/** @param {CancellationSignal | undefined} signal @param {() => void} canceled @returns {() => void} */
export function watchCancellation(signal, canceled) {
  if (!signal) return () => {};
  if (signal.aborted) { canceled(); return () => {}; }
  const id = cancellation.listen(signal, canceled);
  return () => cancellation.unlisten(id);
}

/** @typedef {{ answerer: Answerer, requests: Set<Disposer> }} Registration */
/** @type {Registration[]} */
const answerers = [];
let pending = 0;

function unavailable() {
  return Object.assign(new Error("no interaction answerer is installed"), { name: "InteractionUnavailable" });
}

export const interaction = {
  /** @param {Answerer} answerer @returns {Disposer} */
  install(answerer) {
    if (!answerer || typeof answerer.interactive !== "boolean" || typeof answerer.notify !== "function" || (answerer.interactive && typeof answerer.open !== "function")) {
      throw new TypeError("an answerer needs interactive, notify, and an open method for prompts");
    }
    /** @type {Registration} */
    const entry = { answerer, requests: new Set() };
    answerers.push(entry);
    return () => {
      const at = answerers.indexOf(entry);
      if (at < 0) return;
      answerers.splice(at, 1);
      for (const cancel of entry.requests) cancel();
    };
  },
};

/** @param {Context} ctx @param {InteractionRequest} request @param {InteractionOptions} [options] @returns {Promise<any>} */
function ask(ctx, request, options) {
  return new Promise((resolve, reject) => {
    if (options !== undefined && (options === null || typeof options !== "object" || Array.isArray(options))) throw new TypeError("interaction options must be an object");
    if (options?.signal !== undefined) native.validateSignal(options.signal);
    if (!ctx.alive || options?.signal?.aborted) { resolve(undefined); return; }
    const entry = answerers[answerers.length - 1];
    if (!entry) { reject(unavailable()); return; }
    if (!entry.answerer.interactive) {
      entry.answerer.notify(ctx.id, "denied: " + request.title, "warn");
      resolve(request.type === "confirm" ? false : undefined);
      return;
    }
    let opening = true;
    let done = false;
    let counted = false;
    let failed = false;
    /** @type {unknown} */
    let result;
    let close = () => {};
    let release = () => {};
    const complete = () => {
      entry.requests.delete(cancel);
      release();
      try { close(); } catch (error) { failed = true; result = error; }
      if (counted) {
        pending--;
        events.emit("interaction.changed");
      }
      if (failed) reject(result);
      else resolve(result);
    };
    /** @param {unknown} value @param {boolean} failure */
    const finish = (value, failure) => {
      if (done) return;
      done = true;
      result = value;
      failed = failure;
      if (!opening) complete();
    };
    const cancel = () => finish(undefined, false);
    release = ctx.effect(() => cancel);
    entry.requests.add(cancel);
    try {
      close = entry.answerer.open(request, ctx, options, value => finish(value, false), error => finish(error, true));
      if (typeof close !== "function") throw new TypeError("an answerer must return a synchronous disposer");
    } catch (error) {
      close = typeof close === "function" ? close : () => {};
      done = true;
      failed = true;
      result = error;
    }
    opening = false;
    if (done) complete();
    else {
      counted = true;
      pending++;
      events.emit("interaction.changed");
    }
  });
}

/** @param {Context} ctx @returns {InteractionSurface} */
export function bindInteraction(ctx) {
  return {
    get pending() { return pending; },
    get interactive() { return ctx.alive && (answerers[answerers.length - 1]?.answerer.interactive ?? false); },
    confirm(title, message = "", options) { return ask(ctx, confirmRequest(title, message), options); },
    select(title, choices, options) { return ask(ctx, selectRequest(title, choices), options); },
    input(title, placeholder, options) { return ask(ctx, inputRequest(title, placeholder, options?.secret), options); },
    deviceLogin(start, outcome, options) {
      text(start?.verification_url, "verification URL");
      text(start?.user_code, "user code");
      if (!(outcome instanceof Promise)) throw new TypeError("the login outcome must be a promise");
      return ask(ctx, { type: "device_login", title: "Provider login", start, outcome }, options);
    },
    notify(message, level = "info") {
      text(message, "notify message");
      noticeLevel(level);
      if (!ctx.alive) return;
      const entry = answerers[answerers.length - 1];
      if (!entry) throw unavailable();
      entry.answerer.notify(ctx.id, message, level);
    },
  };
}

/** @type {Answerer} */
const rpcAnswerer = {
  interactive: true,
  open(request, ctx, options, resolve, reject) {
    if (request.type === "device_login") {
      native.notify(ctx.id, "Sign in at " + request.start.verification_url + " with code " + request.start.user_code + ". Cancel the tool to stop setup.", "info");
      request.outcome.then(resolve, reject);
      return watchCancellation(options?.signal, () => resolve(undefined));
    }
    const id = allocateId();
    native.request(id, JSON.stringify(request), options?.signal).then(resolve, reject);
    return () => { native.cancel(id); };
  },
  notify: (owner, message, level) => native.notify(owner, message, level),
};

export const rpcInteractionPlugin = {
  name: "rpc-interaction",
  /** @param {Context} ctx */
  apply(ctx) { ctx.effect(() => interaction.install(rpcAnswerer)); },
};

export const printInteractionPlugin = {
  name: "print-interaction",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.effect(() => interaction.install({ interactive: false, notify: rpcAnswerer.notify }));
  },
};
