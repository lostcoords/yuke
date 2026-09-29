import * as native from "yuke:internal/native/http";

/** @import { FetchOptions, HttpHead, ReadOptions } from "yuke:internal/native/http" */

/** The response header fields. */
class Headers {
  /** @param {Record<string, string>} values */
  constructor(values) { this._values = values; }

  /** Read one field; the name ignores case. A missing field answers null, and a repeated field joins its values with ", ". @param {string} name @returns {string | null} */
  get(name) { return typeof name === "string" ? this._values[name.toLowerCase()] ?? null : null; }
}

// Each read pulls one chunk, so nothing queues on either side.
/** The response body. It waits in the host until a read pulls it. Each read inherits the deadline and the signal of the request. */
class Body {
  /** @param {number} id @param {ReadOptions} defaults */
  constructor(id, defaults) {
    this._id = id;
    this._defaults = defaults;
    // The host frees a body at its end, so this handle remembers the end for later reads.
    this._done = id === 0;
  }

  /** Read the next text chunk, cut on a character boundary. It answers null at the end, and a concurrent read rejects. @param {ReadOptions} [options] @returns {Promise<string | null>} */
  async read(options) {
    if (this._done) return null;
    const chunk = await native.read(this._id, { ...this._defaults, ...options });
    if (chunk === null) this._done = true;
    return chunk;
  }

  /** Read the rest of the body as text. It rejects above 256 KiB, and a body that ended answers "". @param {ReadOptions} [options] @returns {Promise<string>} */
  async readAll(options) {
    if (this._done) return "";
    const rest = await native.readAll(this._id, { ...this._defaults, ...options });
    this._done = true;
    return rest;
  }

  /** Drop the rest of the body and its connection. A second call does nothing. @returns {void} */
  cancel() { if (!this._done) native.close(this._id); }

  /** @returns {AsyncGenerator<string, void, undefined>} */
  async *[Symbol.asyncIterator]() {
    let chunk;
    while ((chunk = await this.read()) !== null) yield chunk;
  }
}

/** One HTTP response. `text` and `json` read the whole body, and `body` reads it in chunks. A body reads only once. */
class Response {
  /** @param {HttpHead} head @param {ReadOptions} defaults */
  constructor(head, defaults) {
    /** The HTTP status code. */
    this.status = head.status;
    /** True for a 2xx status. */
    this.ok = head.status >= 200 && head.status < 300;
    this.headers = new Headers(head.headers);
    /** The body in chunks. Use it for a body above 256 KiB or a stream. */
    this.body = new Body(head.body, defaults);
    /** @type {Promise<string> | undefined} */
    this._text = undefined;
  }

  /** The whole body as text. It rejects above 256 KiB. A second call answers the same Promise. @returns {Promise<string>} */
  text() { return this._text ??= this.body.readAll(); }

  /** The body parsed as JSON. It rejects for a body that is not JSON. @returns {Promise<any>} */
  async json() { return JSON.parse(await this.text()); }
}

/**
 * Send one HTTP request, and resolve at the response head. A 3xx status answers the head alone, with no redirect.
 * A non-2xx status resolves; read `ok` or `status`. A network failure, the deadline, or a signal cancel rejects.
 * @param {string} url @param {FetchOptions} [options] @returns {Promise<Response>}
 */
export async function fetch(url, options) {
  const head = await native.fetch(url, options);
  // The body reads inherit the deadline and the signal of the request.
  /** @type {ReadOptions} */
  const defaults = {};
  if (options?.timeoutMs !== undefined) defaults.timeoutMs = options.timeoutMs;
  if (options?.signal !== undefined) defaults.signal = options.signal;
  return new Response(head, defaults);
}
