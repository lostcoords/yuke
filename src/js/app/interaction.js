// yuke:interaction — the shared question contract and the RPC answerer.
import { interaction } from "yuke:ext";
import { native } from "yuke:interaction-native";

const MAX_SAFE_ID = Number.MAX_SAFE_INTEGER;
let nextId = 1;

// A UTF-16 unit costs at most three UTF-8 bytes, so a short string needs no walk.
/** @param {string} value @returns {boolean} */
function withinTextLimit(value) {
  if (value.length * 3 <= native.maxTextBytes) return true;
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length && value.charCodeAt(i + 1) >= 0xdc00 && value.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i += 1;
    } else bytes += 3;
    if (bytes > native.maxTextBytes) return false;
  }
  return true;
}

/** @param {unknown} value @param {string} name @param {boolean} [empty] @returns {string} */
function text(value, name, empty = false) {
  if (typeof value !== "string") throw new TypeError(name + " must be a string");
  if ((!empty && value.length === 0) || !withinTextLimit(value)) {
    throw new TypeError(name + " has an invalid length");
  }
  return value;
}

/** @param {string} title @param {string} message @returns {{ type: "confirm", title: string, message: string }} */
export function confirmRequest(title, message) {
  return { type: "confirm", title: text(title, "confirm title"), message: text(message, "confirm message", true) };
}

/** @param {string} title @param {string[]} options @returns {{ type: "select", title: string, options: string[] }} */
export function selectRequest(title, options) {
  title = text(title, "select title");
  if (!Array.isArray(options) || options.length === 0 || options.length > native.maxOptions) {
    throw new TypeError("select options must be a non-empty bounded array");
  }
  const values = options.map((option) => text(option, "select option"));
  if (new Set(values).size !== values.length) throw new TypeError("select options must be unique");
  return { type: "select", title, options: values };
}

/** @param {string} title @param {string | undefined} placeholder @returns {{ type: "input", title: string, placeholder?: string }} */
export function inputRequest(title, placeholder) {
  const request = { type: /** @type {const} */ ("input"), title: text(title, "input title") };
  if (placeholder !== undefined) Object.assign(request, { placeholder: text(placeholder, "input placeholder", true) });
  return request;
}

/** @param {unknown} level @returns {"info" | "warn" | "error"} */
export function noticeLevel(level) {
  if (level !== "info" && level !== "warn" && level !== "error") throw new TypeError("notify level is invalid");
  return level;
}

// A wrap reuses an id the host may still hold, and the host answers `Duplicate` if it does.
function allocateId() {
  const id = nextId;
  nextId = nextId === MAX_SAFE_ID ? 1 : nextId + 1;
  return id;
}

const rpcAnswerer = {
  /** @param {import("yuke:ext").Context} ctx */
  surfaceFor(ctx) {
    const live = new Set();
    ctx.effect(() => () => {
      for (const id of live) native.cancel(id);
      live.clear();
    });

    /** @param {object} request @returns {Promise<any>} */
    const ask = (request) => {
      const id = allocateId();
      live.add(id);
      return native.request(id, JSON.stringify(request)).finally(() => live.delete(id));
    };

    return {
      /** @param {string} title @param {string} [message] @returns {Promise<boolean | undefined>} */
      confirm(title, message = "") {
        return ask(confirmRequest(title, message));
      },
      /** @param {string} title @param {string[]} options @returns {Promise<string | undefined>} */
      select(title, options) {
        return ask(selectRequest(title, options));
      },
      /** @param {string} title @param {string} [placeholder] @returns {Promise<string | undefined>} */
      input(title, placeholder) {
        return ask(inputRequest(title, placeholder));
      },
      /** @param {string} message @param {"info" | "warn" | "error"} [level] @returns {void} */
      notify(message, level = "info") {
        native.notify(ctx.id, text(message, "notify message"), noticeLevel(level));
      },
    };
  },
};

export const rpcInteractionPlugin = {
  name: "rpc-interaction",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.effect(() => interaction.install(rpcAnswerer));
  },
};
