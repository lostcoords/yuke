import * as native from "yuke:http-native";

/** @import { FetchOptions, HttpHead, ReadOptions } from "yuke:http-native" */

class Headers {
  /** @param {Record<string, string>} values */
  constructor(values) { this._values = values; }

  /** @param {string} name @returns {string | null} */
  get(name) { return typeof name === "string" ? this._values[name.toLowerCase()] ?? null : null; }
}

// The body waits in the host. Each read pulls one chunk, so nothing queues on either side.
class Body {
  /** @param {number} id @param {ReadOptions} defaults */
  constructor(id, defaults) {
    this._id = id;
    this._defaults = defaults;
    // The host frees a body at its end, so this handle remembers the end for later reads.
    this._done = id === 0;
  }

  /** @param {ReadOptions} [options] @returns {Promise<string | null>} */
  async read(options) {
    if (this._done) return null;
    const chunk = await native.read(this._id, { ...this._defaults, ...options });
    if (chunk === null) this._done = true;
    return chunk;
  }

  /** @param {ReadOptions} [options] @returns {Promise<string>} */
  async readAll(options) {
    if (this._done) return "";
    const rest = await native.readAll(this._id, { ...this._defaults, ...options });
    this._done = true;
    return rest;
  }

  /** @returns {void} */
  cancel() { if (!this._done) native.close(this._id); }

  /** @returns {AsyncGenerator<string, void, undefined>} */
  async *[Symbol.asyncIterator]() {
    let chunk;
    while ((chunk = await this.read()) !== null) yield chunk;
  }
}

class Response {
  /** @param {HttpHead} head @param {ReadOptions} defaults */
  constructor(head, defaults) {
    this.status = head.status;
    this.ok = head.status >= 200 && head.status < 300;
    this.headers = new Headers(head.headers);
    this.body = new Body(head.body, defaults);
    /** @type {Promise<string> | undefined} */
    this._text = undefined;
  }

  /** @returns {Promise<string>} */
  text() { return this._text ??= this.body.readAll(); }

  /** @returns {Promise<any>} */
  async json() { return JSON.parse(await this.text()); }
}

/** @param {string} url @param {FetchOptions} [options] @returns {Promise<Response>} */
export async function fetch(url, options) {
  const head = await native.fetch(url, options);
  // The body reads inherit the deadline and the signal of the request.
  /** @type {ReadOptions} */
  const defaults = {};
  if (options?.timeoutMs !== undefined) defaults.timeoutMs = options.timeoutMs;
  if (options?.signal !== undefined) defaults.signal = options.signal;
  return new Response(head, defaults);
}
