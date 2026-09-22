// yuke:mcp-transport — how MCP messages travel: a child's stdio, Streamable HTTP, or the old HTTP+SSE transport.
import * as cancellation from "yuke:cancellation-native";
import { env } from "yuke:env";
import { spawn, lines } from "yuke:spawn";
import { fetch } from "yuke:http";
import { sseParser } from "yuke:sse";

/** @typedef {import("yuke:cancellation-native").CancellationSignal} CancellationSignal */
/** @typedef {Awaited<ReturnType<typeof fetch>>} HttpResponse */
/** @typedef {{ type?: string, command?: string, args?: string[], env?: Record<string, string>, cwd?: string, url?: string, headers?: Record<string, string>, enabled?: boolean, timeout?: number, alwaysLoad?: boolean }} ServerConfig */

const STOP_GRACE_MS = 2000;
// The server's own timers bound a call, so an HTTP exchange waits as long as the host allows.
const HTTP_WAIT_MS = 600_000;
// A GET stream that breaks reconnects after this delay, doubled up to the cap.
const LISTEN_RETRY_MS = 1000;
const LISTEN_RETRY_MAX_MS = 30_000;
const VERSION_KEY = "io.modelcontextprotocol/protocolVersion";
const ERROR_TEXT_MAX = 200;
const VAR = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g;

/** @param {unknown} error @returns {string} */
const errorText = (error) => (error instanceof Error ? error.message : String(error));

/** @param {any} value @returns {boolean} */
function record(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

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

// The message for a wrong transport entry, or null.
/** @param {ServerConfig} config @param {string} type @returns {string | null} */
export function checkTransport(config, type) {
  if (type === "stdio") return checkStdio(config);
  if (type === "http" || type === "sse") return checkRemote(config);
  return "type must be stdio, http, or sse";
}

// A transport moves JSON-RPC text; the server decodes it. `closed` fires once, when the transport can carry no more.
/** @typedef {{ message(text: string): void, closed(reason: string): void }} Sink */
// `send` settles when the transport has carried the whole exchange; a request whose answer never came rejects.
// `negotiated` names the legacy version after `initialize`; a transport that never hears it speaks the modern era.
/** @typedef {{ send(message: Record<string, unknown>): Promise<void>, cancel(id: number, reason: string): void, negotiated(version: string): void, close(): Promise<void>, diagnostics(failed: boolean): string[] }} Transport */
// What a trusted configuration runs. `identity` keys the trust record, and `describe` names the action in the prompt.
/** @typedef {{ identity: string, describe: string, open(sink: Sink): Transport }} Endpoint */

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

// Expand the configuration into what it runs. A missing variable throws here.
/** @param {ServerConfig} config @returns {Endpoint} */
function stdioEndpoint(config) {
  const argv = [expand(config.command ?? ""), ...(config.args ?? []).map(expand)];
  /** @type {Record<string, string>} */
  const env = Object.create(null);
  const entries = Object.entries(config.env ?? {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  for (const [key, value] of entries) env[key] = expand(value);
  const launch = { argv, env, ...(config.cwd !== undefined ? { cwd: expand(config.cwd) } : {}) };
  return {
    identity: JSON.stringify([config.command, config.args ?? [], config.cwd ?? null, entries, launch]),
    describe: "runs: " + argv.map((arg) => JSON.stringify(arg)).join(" "),
    open: (sink) => openStdio(launch, sink),
  };
}

// The scheme and the authority of an absolute URL.
/** @param {string} url @returns {string} */
function originOf(url) {
  return /^https?:\/\/[^/?#]+/i.exec(url)?.[0]?.toLowerCase() ?? "";
}

// Resolve the old transport's endpoint against the stream URL. Another origin could read the requests, so it is refused.
/** @param {string} base @param {string} target @returns {string} */
function endpointUrl(base, target) {
  const origin = originOf(base);
  const resolved = /^https?:\/\//i.test(target) ? target : target.startsWith("/") ? origin + target : base.replace(/[?#].*$/, "").replace(/[^/]*$/, "") + target;
  if (originOf(resolved) !== origin) throw new Error("the event stream names an endpoint on another origin");
  return resolved;
}

// The response head says what the body holds; a parameter such as a charset does not change the type.
/** @param {HttpResponse} response @returns {string} */
function mediaType(response) {
  const value = response.headers.get("content-type") ?? "";
  const end = value.indexOf(";");
  return (end < 0 ? value : value.slice(0, end)).trim().toLowerCase();
}

/** @param {HttpResponse} response @returns {Promise<string>} */
async function failureText(response) {
  // An HTML error page says nothing a row can show.
  const body = mediaType(response) === "text/html" ? (response.body.cancel(), "") : (await response.text().catch(() => "")).trim().slice(0, ERROR_TEXT_MAX);
  return "the server answered HTTP " + response.status + (body ? ": " + body : "");
}

// Hand each event of the body to `onData` until the body ends.
/** @param {HttpResponse} response @param {(data: string, event: string) => void} onData */
async function readEvents(response, onData) {
  const feed = sseParser((event) => onData(event.data, event.event));
  for await (const chunk of response.body) feed(chunk);
}

/** @param {Record<string, string>} headers @param {Record<string, string>} extra @returns {Record<string, string>} */
function withHeaders(headers, extra) {
  /** @type {Record<string, string>} */
  const merged = Object.create(null);
  // The host refuses one name twice, so every name is lowercase and the transport's own names win.
  for (const [name, value] of Object.entries(headers)) merged[name.toLowerCase()] = value;
  for (const [name, value] of Object.entries(extra)) merged[name] = value;
  return merged;
}

// Streamable HTTP: one POST per message. A request's answer arrives as JSON or on its own event stream.
/** @param {{ url: string, headers: Record<string, string> }} target @param {Sink} sink @returns {Transport} */
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

  /** @param {Record<string, unknown>} message */
  const headersFor = (message) => {
    const params = /** @type {Record<string, any> | undefined} */ (message.params);
    const modern = params?._meta?.[VERSION_KEY];
    /** @type {Record<string, string>} */
    const extra = { "content-type": "application/json", accept: "application/json, text/event-stream" };
    if (typeof modern === "string") {
      // The modern body and header must agree, and the routing headers name the method and its target.
      extra["mcp-protocol-version"] = modern;
      if (typeof message.method === "string") extra["mcp-method"] = message.method;
      if (typeof params?.name === "string") extra["mcp-name"] = params.name;
    } else if (version) extra["mcp-protocol-version"] = version;
    if (session) extra["mcp-session-id"] = session;
    return withHeaders(target.headers, extra);
  };

  // The legacy era may push notifications on one GET stream. A server without one answers 405.
  const listen = async () => {
    let delay = LISTEN_RETRY_MS;
    while (open) {
      const signal = cancellation.create();
      listening = signal;
      try {
        const extra = /** @type {Record<string, string>} */ ({ accept: "text/event-stream", "mcp-protocol-version": version });
        if (session) extra["mcp-session-id"] = session;
        const response = await fetch(target.url, { method: "GET", headers: withHeaders(target.headers, extra), signal, timeoutMs: HTTP_WAIT_MS });
        if (response.status === 405 || !response.ok || mediaType(response) !== "text/event-stream") { response.body.cancel(); return; }
        delay = LISTEN_RETRY_MS;
        await readEvents(response, (data) => { if (open) sink.message(data); });
      } catch (error) {
        if (!open) return;
        lastError = errorText(error);
      }
      await new Promise((resolve) => { retry = setTimeout(() => resolve(undefined), delay); });
      delay = Math.min(delay * 2, LISTEN_RETRY_MAX_MS);
    }
  };

  /** @param {Record<string, unknown>} message */
  const send = async (message) => {
    if (!open) throw new Error("the server is not running");
    const id = typeof message.method === "string" && typeof message.id === "number" ? message.id : undefined;
    const signal = cancellation.create();
    if (id !== undefined) exchanges.set(id, signal);
    try {
      const response = await fetch(target.url, { method: "POST", headers: headersFor(message), body: JSON.stringify(message), signal, timeoutMs: HTTP_WAIT_MS });
      const assigned = response.headers.get("mcp-session-id");
      if (message.method === "initialize" && assigned) session = assigned;
      if (response.status === 404 && session) {
        response.body.cancel();
        closed("the server ended the session");
        throw new Error("the server ended the session");
      }
      if (!response.ok) throw new Error(await failureText(response));
      if (message.method === "notifications/initialized" && version) listen();
      if (id === undefined || response.status === 202) { response.body.cancel(); return; }
      const type = mediaType(response);
      if (type === "application/json") { if (open) sink.message(await response.text()); return; }
      if (type !== "text/event-stream") { response.body.cancel(); throw new Error("the server answered " + (type || "no content type")); }
      await readEvents(response, (data) => { if (open) sink.message(data); });
      // The stream ended; a request it never answered fails, and an answered one ignores this.
      throw new Error("the response stream ended without an answer");
    } finally {
      if (id !== undefined) exchanges.delete(id);
    }
  };

  /** @param {string} reason */
  const closed = (reason) => {
    if (!open) return;
    open = false;
    for (const signal of exchanges.values()) cancellation.cancel(signal);
    sink.closed(reason);
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
      open = false;
      clearTimeout(retry);
      if (listening) cancellation.cancel(listening);
      for (const signal of exchanges.values()) cancellation.cancel(signal);
      // A legacy session ends with DELETE; a failure changes nothing for the client.
      if (session) await fetch(target.url, { method: "DELETE", headers: withHeaders(target.headers, { "mcp-session-id": session, "mcp-protocol-version": version }) }).then((response) => response.body.cancel(), () => {});
    },
    diagnostics() { return lastError ? ["listen: " + lastError] : []; },
  };
}

// The old HTTP+SSE transport: one GET stream carries every server message, and its first event names the POST endpoint.
/** @param {{ url: string, headers: Record<string, string> }} target @param {Sink} sink @returns {Transport} */
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
  /** @param {string} reason */
  const closed = (reason) => {
    lost(new Error(reason));
    if (!open) return;
    open = false;
    cancellation.cancel(stream);
    sink.closed(reason);
  };
  (async () => {
    const response = await fetch(target.url, { method: "GET", headers: withHeaders(target.headers, { accept: "text/event-stream" }), signal: stream, timeoutMs: HTTP_WAIT_MS });
    if (!response.ok) throw new Error(await failureText(response));
    if (mediaType(response) !== "text/event-stream") { response.body.cancel(); throw new Error("the server answered no event stream"); }
    await readEvents(response, (data, event) => {
      if (!open) return;
      if (event === "endpoint") found(endpointUrl(target.url, data.trim()));
      else if (event === "message") sink.message(data);
    });
    throw new Error("the event stream ended");
  })().catch((error) => closed(errorText(error)));
  /** @param {Record<string, unknown>} message */
  const send = async (message) => {
    if (!open) throw new Error("the server is not running");
    const url = await endpoint;
    // The answer arrives on the stream, so the POST only has to be accepted.
    const response = await fetch(url, { method: "POST", headers: withHeaders(target.headers, { "content-type": "application/json" }), body: JSON.stringify(message), timeoutMs: HTTP_WAIT_MS });
    if (!response.ok) throw new Error(await failureText(response));
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
  const entries = Object.entries(config.headers ?? {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
  /** @type {Record<string, string>} */
  const headers = Object.create(null);
  for (const [name, value] of entries) headers[name] = expand(value);
  const target = { url, headers };
  return {
    // The store keeps a hash of this, so an expanded secret never reaches the disk.
    identity: JSON.stringify([type, config.url, entries, target]),
    describe: "connects to: " + url,
    open: (sink) => type === "http" ? openHttp(target, sink) : openSse(target, sink),
  };
}

// Expand a checked configuration into its endpoint. A missing variable throws here.
/** @param {ServerConfig} config @param {string} type @returns {Endpoint} */
export function endpointFor(config, type) {
  return type === "stdio" ? stdioEndpoint(config) : remoteEndpoint(config, type === "sse" ? "sse" : "http");
}
