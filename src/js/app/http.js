import { fetch as send } from "yuke:http-native";

/** @typedef {import("yuke:http-native").FetchOptions} FetchOptions */

class Headers {
  /** @param {Record<string, string>} values */
  constructor(values) { this._values = values; }

  /** @param {string} name @returns {string | null} */
  get(name) { return typeof name === "string" ? this._values[name.toLowerCase()] ?? null : null; }
}

class Response {
  /** @param {import("yuke:http-native").HttpResponse} raw */
  constructor(raw) {
    this.status = raw.status;
    this.ok = raw.status >= 200 && raw.status < 300;
    this.headers = new Headers(raw.headers);
    this._body = raw.body;
  }

  /** @returns {Promise<string>} */
  async text() { return this._body; }

  /** @returns {Promise<any>} */
  async json() { return JSON.parse(this._body); }
}

/** @param {string} url @param {FetchOptions} [options] @returns {Promise<Response>} */
export async function fetch(url, options) {
  return new Response(await (arguments.length === 0 ? send() : send(url, options)));
}
