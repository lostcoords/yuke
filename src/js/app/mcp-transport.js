// How MCP messages travel: a child's stdio, Streamable HTTP, or the old HTTP+SSE transport.
import * as cancellation from "yuke:internal/native/cancellation";
import { env } from "yuke:internal/native/env";
import { spawn, lines } from "yuke:internal/spawn";
import { fetch } from "yuke:internal/http";
import { sseParser } from "yuke:internal/sse";
import { utf8 } from "yuke:internal/native/utf8";
import { authFor, record, split } from "yuke:internal/mcp-oauth";
import { errorText } from "yuke:internal/format";

/** @import { CancellationSignal } from "yuke:internal/native/cancellation" */
/** @import { Auth, OAuthConfig } from "yuke:internal/mcp-oauth" */
/** @import { SseEvent } from "yuke:internal/sse" */
/** @typedef {Awaited<ReturnType<typeof fetch>>} HttpResponse */
/** @typedef {{ type?: string, command?: string, args?: string[], env?: Record<string, string>, cwd?: string, url?: string, headers?: Record<string, string>, oauth?: OAuthConfig | false, enabled?: boolean, timeout?: number, alwaysLoad?: boolean }} ServerConfig */
/** @typedef {{ url: string, headers: Record<string, string>, auth: Auth | null }} Target */

const STOP_GRACE_MS = 2000;
// The server's own timers bound a call, so an HTTP exchange waits as long as the host allows.
const HTTP_WAIT_MS = 600_000;
// A notification stream that breaks reconnects after this delay, doubled up to the cap.
export const LISTEN_RETRY_MS = 1000;
export const LISTEN_RETRY_MAX_MS = 30_000;
const VERSION_KEY = "io.modelcontextprotocol/protocolVersion";
const ERROR_TEXT_MAX = 200;
// A result may carry a 7 MiB image as base64 inside JSON, so one answer reads up to this.
const MAX_RESPONSE_CHARS = 16 * 1024 * 1024;
const READ_CHUNK_BYTES = 1024 * 1024;
// The method names whose routing header carries a parameter, and that parameter.
const ROUTED = /** @type {Record<string, string>} */ ({ "tools/call": "name", "prompts/get": "name", "resources/read": "uri" });
const SENTINEL_START = "=?base64?";
const SENTINEL_END = "?=";
const VAR = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g;

// Expand `${VAR}` and `${VAR:-default}`. A missing variable without a default is a config error.
/** @param {string} text @returns {string} */
function expand(text) {
  return text.replace(VAR, (_, name, fallback) => {
    const value = env.get(name);
    if (value !== undefined) return value;
    if (fallback !== undefined) return fallback;
    throw new Error("the environment variable " + name + " is not set");
  });
}

/** @param {ServerConfig} config @returns {string | null} */
function checkRemote(config) {
  if (typeof config.url !== "string" || !/^https?:\/\/[^/?#]/i.test(config.url)) return "url must be an http or https URL";
  if (config.headers !== undefined && !(record(config.headers) && Object.values(config.headers).every((value) => typeof value === "string"))) return "headers must be an object of strings";
  const oauth = config.oauth;
  const valid = oauth === undefined || oauth === false || (record(oauth) && (oauth.clientId === undefined || typeof oauth.clientId === "string") && (oauth.clientSecret === undefined || typeof oauth.clientSecret === "string") && (oauth.scopes === undefined || (Array.isArray(oauth.scopes) && oauth.scopes.every((scope) => typeof scope === "string"))));
  if (!valid) return "oauth must be false or an object with a string clientId, a string clientSecret, and string scopes";
  return null;
}

/** @param {ServerConfig} config @returns {string | null} */
function checkStdio(config) {
  if (typeof config.command !== "string" || config.command === "") return "command must be a nonempty string";
  if (config.args !== undefined && !(Array.isArray(config.args) && config.args.every((arg) => typeof arg === "string"))) return "args must be an array of strings";
  if (config.env !== undefined && !(record(config.env) && Object.entries(config.env).every(([key, value]) => key !== "" && !/[=\0]/.test(key) && typeof value === "string" && !value.includes("\0")))) return "env must be an object of strings";
  if (config.cwd !== undefined && typeof config.cwd !== "string") return "cwd must be a string";
  if (config.command.includes("\0") || config.args?.some((arg) => arg.includes("\0")) || config.cwd?.includes("\0")) return "execution fields must not contain NUL";
  return null;
}

// A transport moves JSON-RPC text; the server decodes it and answers the id of the request that the text settles.
// `closed` fires once, when the transport can carry no more; `reconnect` asks the server to start again, and `signIn` carries a 401 challenge.
/** @typedef {{ message(text: string): number | undefined, closed(reason: string, options?: { reconnect?: boolean, signIn?: string }): void }} Sink */
// `send` settles when the transport has carried the whole exchange; a request whose answer never came rejects.
// `negotiated` names the legacy version after `initialize`; a transport that never hears it speaks the modern era.
/** @typedef {{ send(message: Record<string, unknown>, headers?: Record<string, string>): Promise<void>, cancel(id: number, reason: string): void, negotiated(version: string): void, close(): Promise<void>, diagnostics(failed: boolean): string[] }} Transport */
// What a trusted configuration runs. `identity` keys the trust record, `describe` names the action in the prompt, and `mirrorsParams` means the tool headers apply.
// A remote endpoint names its `url`, and `signsIn` means an OAuth sign-in can give it a token.
/** @typedef {{ identity: string, describe: string, mirrorsParams: boolean, url?: string, signsIn?: boolean, open(sink: Sink): Transport }} Endpoint */

// One child process per server. Each stdout line is one message; a line that is not JSON is noise.
/** @param {{ argv: string[], env: Record<string, string>, cwd?: string }} launch @param {Sink} sink @returns {Transport} */
function openStdio(launch, sink) {
  let noise = 0;
  /** @type {string | undefined} */
  let stderr;
  let open = true;
  /** @param {string} reason */
  const closed = (reason) => { if (open) { open = false; sink.closed(reason); } };
  const child = spawn(launch.argv, { env: launch.env, ...(launch.cwd !== undefined ? { cwd: launch.cwd } : {}) });
  child.onStdout(lines((line) => {
    const first = line.trimStart()[0];
    if (first !== "{" && first !== "[") { noise += 1; return; }
    if (open) sink.message(line);
  }, () => closed("the MCP frame exceeds the line limit")));
  child.onStderr(lines((line) => { stderr = line; }));
  child.exited.then(
    (exit) => closed(exit.signal != null ? "the server ended on signal " + exit.signal : "the server exited with code " + exit.code),
    (error) => closed("the server did not start: " + errorText(error)),
  );
  /** @param {Record<string, unknown>} message */
  const send = (message) => open ? child.write(JSON.stringify(message) + "\n") : Promise.reject(new Error("the server is not running"));
  return {
    send,
    cancel(id, reason) { send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: id, reason } }).catch(() => {}); },
    negotiated() {},
    // The MCP stdio shutdown: stdin EOF, a grace period, then TERM and KILL through `kill`.
    async close() {
      open = false;
      child.closeStdin();
      let grace = 0;
      const exited = await Promise.race([child.exited.then(() => true, () => true), new Promise((resolve) => { grace = setTimeout(() => resolve(false), STOP_GRACE_MS); })]);
      clearTimeout(grace);
      if (!exited) child.kill();
      await child.exited.catch(() => {});
    },
    diagnostics(failed) {
      /** @type {string[]} */
      const parts = [];
      if (failed && stderr !== undefined) parts.push("stderr: " + stderr);
      if (noise) parts.push(noise + (noise === 1 ? " stray stdout line" : " stray stdout lines"));
      return parts;
    },
  };
}

// Expand every value of a configured map. The sorted entries key the trust, so a reorder is not a new server.
/** @param {Record<string, string> | undefined} map @returns {{ entries: [string, string][], values: Record<string, string> }} */
function expandAll(map) {
  const entries = Object.entries(map ?? {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  /** @type {Record<string, string>} */
  const values = Object.create(null);
  for (const [key, value] of entries) values[key] = expand(value);
  return { entries, values };
}

// Expand the configuration into what it runs. A missing variable throws here.
/** @param {ServerConfig} config @returns {Endpoint} */
function stdioEndpoint(config) {
  const argv = [expand(config.command ?? ""), ...(config.args ?? []).map(expand)];
  const { entries, values: env } = expandAll(config.env);
  const launch = { argv, env, ...(config.cwd !== undefined ? { cwd: expand(config.cwd) } : {}) };
  return {
    identity: JSON.stringify([config.command, config.args ?? [], config.cwd ?? null, entries, launch]),
    describe: "runs: " + argv.map((arg) => JSON.stringify(arg)).join(" "),
    mirrorsParams: false,
    open: (sink) => openStdio(launch, sink),
  };
}

// Resolve the old transport's endpoint against the stream URL. Reject a different origin because it could read the requests.
/** @param {string} base @param {string} target @returns {string} */
function endpointUrl(base, target) {
  const origin = split(base).origin;
  const resolved = /^https?:\/\//i.test(target) ? target : target.startsWith("/") ? origin + target : base.replace(/[?#].*$/, "").replace(/[^/]*$/, "") + target;
  if (split(resolved).origin !== origin) throw new Error("the event stream names an endpoint on another origin");
  return resolved;
}

// The response head says what the body holds; a parameter such as a charset does not change the type.
/** @param {HttpResponse} response @returns {string} */
function mediaType(response) {
  const value = response.headers.get("content-type") ?? "";
  const end = value.indexOf(";");
  return (end < 0 ? value : value.slice(0, end)).trim().toLowerCase();
}

// Read the whole body in chunks. `text()` stops at 256 KiB, and an image result is larger.
/** @param {HttpResponse} response @param {number} max @returns {Promise<string>} */
async function readText(response, max) {
  try {
    let text = "";
    let chunk;
    while ((chunk = await response.body.read({ maxBytes: READ_CHUNK_BYTES })) !== null) {
      text += chunk;
      if (text.length > max) throw new Error("the response exceeds the size limit");
    }
    return text;
  } finally {
    response.body.cancel();
  }
}

// The error of a refused request. A JSON-RPC error body keeps its code and data, so a modern server's answer is not a legacy one.
/** @param {HttpResponse} response @returns {Promise<Error>} */
async function failure(response) {
  if (mediaType(response) === "text/html") {
    response.body.cancel();
    return Object.assign(new Error("the server answered HTTP " + response.status), { status: response.status });
  }
  const body = (await readText(response, READ_CHUNK_BYTES).catch(() => "")).trim();
  if (mediaType(response) === "application/json") {
    let parsed;
    try { parsed = JSON.parse(body); } catch { parsed = null; }
    const error = parsed?.error;
    if (parsed?.jsonrpc === "2.0" && record(error) && Number.isSafeInteger(error.code) && typeof error.message === "string") return Object.assign(new Error(error.message), { code: error.code, data: error.data, status: response.status });
  }
  return Object.assign(new Error("the server answered HTTP " + response.status + (body ? ": " + body.slice(0, ERROR_TEXT_MAX) : "")), { status: response.status });
}

// Hand each event of the body to `onEvent` until the body ends. The body is released on every exit.
/** @param {HttpResponse} response @param {(event: SseEvent) => void} onEvent @param {(ms: number) => void} [onRetry] */
async function readEvents(response, onEvent, onRetry) {
  try {
    const feed = sseParser(onEvent, { maxChars: MAX_RESPONSE_CHARS, onRetry });
    let chunk;
    while ((chunk = await response.body.read({ maxBytes: READ_CHUNK_BYTES })) !== null) feed(chunk);
  } finally {
    response.body.cancel();
  }
}

// A header value that is not plain visible ASCII, or that looks like the sentinel, travels as base64 in the sentinel form.
/** @param {string} value @returns {string} */
export function headerValue(value) {
  const plain = /^[\x21-\x7e](?:[\x20-\x7e\t]*[\x21-\x7e])?$/.test(value) && !(value.startsWith(SENTINEL_START) && value.endsWith(SENTINEL_END));
  if (plain) return value;
  // QuickJS has `toBase64` on byte arrays; the bundled TypeScript library does not name it yet.
  const bytes = /** @type {Uint8Array & { toBase64(): string }} */ (utf8.encode(value));
  return SENTINEL_START + bytes.toBase64() + SENTINEL_END;
}

// Create a sign-in error and preserve the server challenge.
/** @param {HttpResponse} response @returns {Error} */
function signInError(response) {
  response.body.cancel();
  return Object.assign(new Error("the server needs a sign-in"), { signIn: response.headers.get("www-authenticate") ?? "" });
}

// Send one request with the bearer header of a signed-in server. A 401 renews the token once; a second 401 asks for a sign-in.
/** @param {Target} target @param {string} url @param {{ method: "GET" | "POST" | "DELETE", extra: Record<string, string>, body?: string, signal?: CancellationSignal }} request @returns {Promise<HttpResponse>} */
async function exchange(target, url, { method, extra, body, signal }) {
  /** @param {string | null} sent */
  const attempt = (sent) => fetch(url, {
    method,
    // The host refuses one name twice, so every name is lowercase and the transport's own names win.
    headers: { ...Object.fromEntries(Object.entries(target.headers).map(([name, value]) => [name.toLowerCase(), value])), ...extra, ...(sent ? { authorization: sent } : {}) },
    ...(body !== undefined ? { body } : {}),
    ...(signal !== undefined ? { signal } : {}),
    timeoutMs: HTTP_WAIT_MS,
  });
  const auth = target.auth;
  const sent = auth ? await auth.header() : null;
  const response = await attempt(sent);
  if (response.status !== 401 || !auth) return response;
  const challenge = signInError(response);
  if (!(await auth.renew(sent))) throw challenge;
  const again = await attempt(await auth.header());
  if (again.status === 401) throw signInError(again);
  return again;
}

// Streamable HTTP: one POST per message. A request's answer arrives as JSON or on its own event stream.
/** @param {Target} target @param {Sink} sink @returns {Transport} */
function openHttp(target, sink) {
  let open = true;
  // The legacy era keeps a session and names its version in a header; the modern era has neither.
  let version = "";
  let session = "";
  /** @type {Map<number, CancellationSignal>} */
  const exchanges = new Map();
  /** @type {CancellationSignal | null} */
  let listening = null;
  let retry = 0;
  let lastError = "";

  /** @param {Record<string, unknown>} message @param {Record<string, string>} params_headers */
  const headersFor = (message, params_headers) => {
    const params = /** @type {Record<string, unknown> | undefined} */ (message.params);
    const meta = params?._meta;
    const modern = record(meta) ? meta[VERSION_KEY] : undefined;
    /** @type {Record<string, string>} */
    const extra = { "content-type": "application/json", accept: "application/json, text/event-stream" };
    if (typeof modern === "string") {
      // The modern body and header must agree, and the routing headers name the method and its target.
      extra["mcp-protocol-version"] = modern;
      if (typeof message.method === "string") {
        extra["mcp-method"] = message.method;
        const routed = params?.[ROUTED[message.method] ?? ""];
        if (typeof routed === "string") extra["mcp-name"] = headerValue(routed);
      }
      Object.assign(extra, params_headers);
    } else if (version) extra["mcp-protocol-version"] = version;
    if (session) extra["mcp-session-id"] = session;
    return extra;
  };

  // The legacy era may push notifications on one GET stream. A server without one answers 405.
  const listen = async () => {
    let delay = LISTEN_RETRY_MS;
    // The server may ask for a delay, and a reconnect names the last event so the server can resume.
    let asked = 0;
    let lastId = "";
    while (open) {
      const signal = cancellation.create();
      listening = signal;
      try {
        const extra = /** @type {Record<string, string>} */ ({ accept: "text/event-stream", "mcp-protocol-version": version });
        if (session) extra["mcp-session-id"] = session;
        if (lastId) extra["last-event-id"] = lastId;
        const response = await exchange(target, target.url, { method: "GET", extra, signal });
        if (!response.ok || mediaType(response) !== "text/event-stream") { response.body.cancel(); return; }
        delay = LISTEN_RETRY_MS;
        await readEvents(response, (event) => {
          lastId = event.id;
          if (open) sink.message(event.data);
        }, (ms) => { asked = ms; });
      } catch (error) {
        if (!open) return;
        lastError = errorText(error);
      }
      await new Promise((resolve) => { retry = setTimeout(() => resolve(undefined), asked || delay); });
      delay = Math.min(delay * 2, LISTEN_RETRY_MAX_MS);
    }
  };

  /** @param {Record<string, unknown>} message @param {Record<string, string>} [params_headers] */
  const send = async (message, params_headers = {}) => {
    if (!open) throw new Error("the server is not running");
    const id = typeof message.method === "string" && typeof message.id === "number" ? message.id : undefined;
    const signal = cancellation.create();
    if (id !== undefined) exchanges.set(id, signal);
    try {
      const response = await exchange(target, target.url, { method: "POST", extra: headersFor(message, params_headers), body: JSON.stringify(message), signal });
      const assigned = response.headers.get("mcp-session-id");
      if (message.method === "initialize" && assigned) session = assigned;
      // A legacy server that forgets the session wants a new `initialize`, so the server starts again.
      if (response.status === 404 && session) {
        response.body.cancel();
        closed("the server ended the session", { reconnect: true });
        throw new Error("the server ended the session");
      }
      if (!response.ok) throw await failure(response);
      if (message.method === "notifications/initialized" && version) listen();
      if (id === undefined || response.status === 202) { response.body.cancel(); return; }
      const type = mediaType(response);
      if (type === "application/json") {
        const text = await readText(response, MAX_RESPONSE_CHARS);
        if (open) sink.message(text);
        return;
      }
      if (type !== "text/event-stream") { response.body.cancel(); throw new Error("the server answered " + (type || "no content type")); }
      let answered = false;
      await readEvents(response, (event) => {
        if (open && sink.message(event.data) === id) answered = true;
      });
      // A response stream must deliver the request response before it ends.
      if (!answered) throw new Error("the response stream ended without an answer");
    } finally {
      if (id !== undefined) exchanges.delete(id);
    }
  };

  // Stop the listen loop and every exchange, so the transport answers nothing more.
  const stop = () => {
    open = false;
    clearTimeout(retry);
    if (listening) cancellation.cancel(listening);
    for (const signal of exchanges.values()) cancellation.cancel(signal);
  };

  /** @param {string} reason @param {{ reconnect?: boolean }} [options] */
  const closed = (reason, options) => {
    if (!open) return;
    stop();
    sink.closed(reason, options);
  };

  return {
    send,
    cancel(id, reason) {
      // A modern server stops when its stream closes; a legacy one needs the notification.
      if (version) send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: id, reason } }).catch(() => {});
      const signal = exchanges.get(id);
      if (signal) cancellation.cancel(signal);
    },
    negotiated(negotiatedVersion) { version = negotiatedVersion; },
    async close() {
      stop();
      // A legacy session ends with DELETE; a failure changes nothing for the client.
      if (session) await exchange(target, target.url, { method: "DELETE", extra: { "mcp-session-id": session, "mcp-protocol-version": version } }).then((response) => response.body.cancel(), () => {});
    },
    diagnostics() { return lastError ? ["listen: " + lastError] : []; },
  };
}

// The old HTTP+SSE transport: one GET stream carries every server message, and its first event names the POST endpoint.
/** @param {Target} target @param {Sink} sink @returns {Transport} */
function openSse(target, sink) {
  let open = true;
  const stream = cancellation.create();
  /** @type {(url: string) => void} */
  let found = () => {};
  /** @type {(error: Error) => void} */
  let lost = () => {};
  /** @type {Promise<string>} */
  const endpoint = new Promise((resolve, reject) => { found = resolve; lost = reject; });
  endpoint.catch(() => {});
  /** @param {unknown} error */
  const closed = (error) => {
    const reason = errorText(error);
    lost(new Error(reason));
    if (!open) return;
    open = false;
    cancellation.cancel(stream);
    // A 401 on the stream keeps its challenge, so the server can ask for a sign-in.
    sink.closed(reason, error instanceof Error && "signIn" in error ? { signIn: String(error.signIn) } : undefined);
  };
  (async () => {
    const response = await exchange(target, target.url, { method: "GET", extra: { accept: "text/event-stream" }, signal: stream });
    if (!response.ok) throw await failure(response);
    if (mediaType(response) !== "text/event-stream") { response.body.cancel(); throw new Error("the server answered no event stream"); }
    await readEvents(response, (event) => {
      if (!open) return;
      if (event.event === "endpoint") found(endpointUrl(target.url, event.data.trim()));
      else if (event.event === "message") sink.message(event.data);
    });
    throw new Error("the event stream ended");
  })().catch(closed);
  /** @param {Record<string, unknown>} message */
  const send = async (message) => {
    if (!open) throw new Error("the server is not running");
    const url = await endpoint;
    // The answer arrives on the stream, so the POST only has to be accepted.
    const response = await exchange(target, url, { method: "POST", extra: { "content-type": "application/json" }, body: JSON.stringify(message) });
    if (!response.ok) throw await failure(response);
    response.body.cancel();
  };
  return {
    send,
    cancel(id, reason) { send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: id, reason } }).catch(() => {}); },
    negotiated() {},
    async close() {
      open = false;
      lost(new Error("the server stopped"));
      cancellation.cancel(stream);
    },
    diagnostics() { return []; },
  };
}

// Expand the configuration into the URL and headers it sends. A missing variable throws here.
/** @param {ServerConfig} config @param {"http" | "sse"} type @returns {Endpoint} */
function remoteEndpoint(config, type) {
  const url = expand(/** @type {string} */ (config.url));
  const { entries, values: headers } = expandAll(config.headers);
  // A configured Authorization header or `oauth: false` means the user owns the credential.
  const owned = config.oauth === false || Object.keys(headers).some((name) => name.toLowerCase() === "authorization");
  /** @type {Target} */
  const target = { url, headers, auth: owned ? null : authFor(url) };
  return {
    // A rotated secret in a header changes nothing the server can do, so only the expanded URL keys the trust.
    identity: JSON.stringify([type, config.url, entries, url]),
    describe: "connects to: " + url,
    mirrorsParams: type === "http",
    url,
    signsIn: target.auth !== null,
    open: (sink) => type === "http" ? openHttp(target, sink) : openSse(target, sink),
  };
}

// Check a configuration and expand it into its endpoint. A wrong entry or a missing variable throws here.
/** @param {ServerConfig} config @param {string} type @returns {Endpoint} */
export function endpointFor(config, type) {
  const problem = type === "stdio" ? checkStdio(config) : type === "http" || type === "sse" ? checkRemote(config) : "type must be stdio, http, or sse";
  if (problem !== null) throw new Error(problem);
  return type === "stdio" ? stdioEndpoint(config) : remoteEndpoint(config, type === "sse" ? "sse" : "http");
}
