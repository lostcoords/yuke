// yuke:mcp — MCP servers as yuke tools. `.mcp.json` names them; `yuke:mcp-transport` carries each one.
import * as mcpNative from "yuke:mcp-native";
import { sha256 } from "yuke:oauth-native";
import * as cancellation from "yuke:cancellation-native";
import { fs } from "yuke:fs";
import { showInfo } from "yuke:info-panel";
import { endpointFor, headerValue, LISTEN_RETRY_MS, LISTEN_RETRY_MAX_MS } from "yuke:mcp-transport";
import { client } from "yuke:client";
import { signIn, forget, record } from "yuke:mcp-oauth";
import { errorText } from "yuke:format";
import { openUrl } from "yuke:browser";
import { notice } from "yuke:notice";

/** @import { Context } from "yuke:ext" */
/** @import { Plugin, ToolContext, ToolDefinition } from "./types/ext.js" */
/** @import { CancellationSignal } from "yuke:cancellation-native" */
/** @import { Endpoint, ServerConfig, Transport } from "yuke:mcp-transport" */
/** @typedef {{ servers?: Record<string, ServerConfig>, startupMs?: number, callMs?: number }} McpOptions */
/** @typedef {{ startupMs: number, callMs: number }} Limits */
/** @typedef {"pending" | "untrusted" | "connecting" | "connected" | "needs auth" | "failed" | "disabled" | "stopped"} ServerState */
/** @typedef {{ resolve: (value: any) => void, reject: (error: Error) => void, done: () => void, bytes: number, cancelable: boolean, progress?: (value: number, report: Record<string, unknown>) => void }} Waiting */
/** @typedef {{ name: string, path: string[] }} Mirrored */

const WORKSPACE_FILE = ".mcp.json";
const MODERN = "2026-07-28";
const LEGACY = "2025-11-25";
// The legacy versions this client can serve. A server that answers another one gets no requests.
const LEGACY_KNOWN = ["2024-11-05", "2025-03-26", "2025-06-18", LEGACY];
const UNSUPPORTED_VERSION = -32022;
// A modern server refuses a request whose headers disagree with its body; a fallback to legacy would hide that.
const HEADER_MISMATCH = -32020;
const CLIENT = { name: "yuke", version: "0" };
// The modern era carries the version and the client capabilities in every request.
const META = { "io.modelcontextprotocol/protocolVersion": MODERN, "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": CLIENT };
const NAME_MAX = 64;
// The search tool the engine expects by this name; a deferred definition is reachable only through it.
const SEARCH_TOOL = "tool_search";
const INSTRUCTIONS_MAX = 2048;
const SEARCH_DESCRIPTION_MAX = 4096;
const QUERY_MAX = 500;
const DESCRIPTION_MAX = 1024;
const RESULT_MAX = 16 * 1024;
// A loaded schema above this stays out of the context; the search names the tool without it.
const SCHEMA_MAX = 64 * 1024;
const LIMIT_DEFAULT = 5;
const LIMIT_MAX = 20;
const MAX_PAGES = 100;
const MAX_TOOLS = 10_000;
const MAX_CATALOG_BYTES = 4 * 1024 * 1024;
// A call that reports progress restarts its timer on each report, up to this many times its timeout in all.
const PROGRESS_CAP = 10;
// One result attaches at most this many images, as one input does.
const MAX_IMAGES = 8;
// A text result shares this empty list, so it allocates none.
const NO_IMAGES = Object.freeze(/** @type {string[]} */ ([]));
// A result above this reaches the model cut, with a marker that names the missing part.
const MAX_RESULT_CHARS = 100_000;

// `mcp_<server>_<tool>` within the provider limit; an overflow keeps a prefix and a stable hash of the whole name.
/** @param {string} server @param {string} tool @returns {string} */
export function toolName(server, tool) {
  const raw = "mcp_" + server + "_" + tool;
  const clean = raw.replace(/[^A-Za-z0-9_-]/g, "_");
  if (clean.length <= NAME_MAX) return clean;
  // FNV-1a keeps the suffix stable across runs.
  let hash = 0x811c9dc5;
  for (let i = 0; i < raw.length; i++) hash = Math.imul(hash ^ raw.charCodeAt(i), 0x01000193) >>> 0;
  return clean.slice(0, NAME_MAX - 9) + "_" + hash.toString(16).padStart(8, "0");
}

// The model reads text. Every other block becomes a one-line description.
/** @param {any[]} content @param {unknown} structured @returns {string} */
function contentText(content, structured) {
  if (content.length === 1 && content[0].type === "text") {
    const text = content[0].text;
    return text.length <= MAX_RESULT_CHARS ? text : text.slice(0, MAX_RESULT_CHARS) + "\n[truncated " + (text.length - MAX_RESULT_CHARS) + " characters]";
  }
  /** @type {string[]} */
  const parts = [];
  let total = 0, blocks = 0, hasText = false;
  /** @param {string} text */
  const append = (text) => {
    const separator = blocks++ === 0 ? 0 : 1;
    const remaining = MAX_RESULT_CHARS - total - separator;
    if (remaining >= 0) parts.push(text.slice(0, remaining));
    total += separator + text.length;
  };
  for (const block of content) {
    switch (block.type) {
      case "text": append(block.text); hasText = true; break;
      case "image": case "audio": append("[" + block.type + " " + block.mimeType + ", " + Math.floor(block.data.length * 3 / 4) + " bytes]"); break;
      case "resource_link": append("[resource " + block.uri + " " + block.name + "]"); break;
      case "resource": {
        const resource = block.resource;
        if (typeof resource.text === "string") append(resource.text);
        else append("[resource " + resource.uri + (resource.mimeType ? " " + resource.mimeType : "") + "]");
        break;
      }
    }
  }
  if (!hasText && structured !== undefined) append(JSON.stringify(structured));
  const text = parts.join("\n");
  return total <= MAX_RESULT_CHARS ? text : text + "\n[truncated " + (total - MAX_RESULT_CHARS) + " characters]";
}

/** @param {string} message @returns {never} */
function invalid(message) { throw new Error("invalid MCP " + message); }

// Extension fields remain legal; known envelope fields must identify exactly one message kind.
/** @param {string} line @returns {any} */
export function decodeMessage(line) {
  let message;
  try { message = JSON.parse(line); } catch { return invalid("JSON"); }
  if (!record(message) || message.jsonrpc !== "2.0") return invalid("envelope");
  const hasId = Object.hasOwn(message, "id");
  const hasResult = Object.hasOwn(message, "result");
  const hasError = Object.hasOwn(message, "error");
  const id = message.id;
  const validId = typeof id === "string" || Number.isSafeInteger(id);
  if (Object.hasOwn(message, "method")) {
    if (typeof message.method !== "string" || message.method === "" || hasResult || hasError || (hasId && !validId)) return invalid("request");
    if (message.params !== undefined && !record(message.params)) return invalid("request params");
  } else {
    if (!hasId || (!validId && !(id === null && hasError)) || hasResult === hasError || Object.hasOwn(message, "params")) return invalid("response");
    if (hasResult && !record(message.result)) return invalid("response result");
    if (hasError && (!record(message.error) || !Number.isSafeInteger(message.error.code) || typeof message.error.message !== "string")) return invalid("response error");
  }
  return message;
}

/** @param {any} result @param {boolean} modern */
function complete(result, modern) {
  if (!record(result)) return invalid("result");
  if ((modern || result.resultType !== undefined) && result.resultType !== "complete") return invalid("result type");
  if (result._meta !== undefined && !record(result._meta)) return invalid("result metadata");
}

// The catalog owns the parsed schema; validation does not clone or serialize it.
/** @param {any} tool */
function validateTool(tool) {
  if (!record(tool) || typeof tool.name !== "string" || tool.name === "" || tool.name.length > 1024) return invalid("tool name");
  if (tool.description !== undefined && typeof tool.description !== "string") return invalid("tool description");
  if (tool.title !== undefined && typeof tool.title !== "string") return invalid("tool title");
  const schema = tool.inputSchema;
  if (!record(schema) || schema.type !== "object") return invalid("tool input schema");
  if (schema.properties !== undefined && !record(schema.properties)) return invalid("tool properties");
  if (schema.required !== undefined && (!Array.isArray(schema.required) || !schema.required.every((/** @type {any} */ name) => typeof name === "string"))) return invalid("tool required fields");
  if (tool.outputSchema !== undefined && (!record(tool.outputSchema) || tool.outputSchema.type !== "object")) return invalid("tool output schema");
}

/** @param {any} block */
function validateContent(block) {
  if (!record(block)) return invalid("content block");
  switch (block.type) {
    case "text":
      if (typeof block.text !== "string") return invalid("text content");
      break;
    case "image": case "audio":
      if (typeof block.data !== "string" || typeof block.mimeType !== "string" || !block.mimeType) return invalid("media content");
      break;
    case "resource_link":
      if (typeof block.uri !== "string" || !block.uri || typeof block.name !== "string") return invalid("resource link");
      break;
    case "resource": {
      const resource = block.resource;
      if (!record(resource) || typeof resource.uri !== "string" || !resource.uri) return invalid("resource content");
      if (typeof resource.text !== "string" && typeof resource.blob !== "string") return invalid("resource body");
      if (resource.mimeType !== undefined && typeof resource.mimeType !== "string") return invalid("resource MIME type");
      break;
    }
    default: return invalid("content type");
  }
}

// The text the model reads, and the base64 image bytes that go beside it.
/** @param {any} result @param {boolean} [modern] @returns {{ text: string, images: readonly string[] }} */
export function toolResult(result, modern = false) {
  if (record(result) && modern && result.resultType === "input_required") throw new Error("the tool asks for input, which this client cannot answer");
  complete(result, modern);
  if (!Array.isArray(result.content)) return invalid("tool content");
  if (result.isError !== undefined && typeof result.isError !== "boolean") return invalid("tool error flag");
  if (result.structuredContent !== undefined && !record(result.structuredContent)) return invalid("structured content");
  for (const block of result.content) validateContent(block);
  const text = contentText(result.content, result.structuredContent);
  if (result.isError === true) throw new Error(text || "the tool failed");
  /** @type {string[] | null} */
  let images = null;
  for (const block of result.content) {
    if (block.type !== "image") continue;
    images ??= [];
    if (images.length < MAX_IMAGES) images.push(block.data);
  }
  return { text, images: images ?? NO_IMAGES };
}

// One progress report as a line: the message, then the step and the total when the server names them.
/** @param {Record<string, unknown>} report @returns {string} */
function progressLine(report) {
  const step = typeof report.total === "number" ? report.progress + "/" + report.total : String(report.progress);
  // A peer message can hold line breaks, so one report stays one line.
  const message = typeof report.message === "string" ? report.message.replace(/[\r\n]+/g, " ").trim() : "";
  return (message !== "" ? message + " (" + step + ")" : "progress " + step) + "\n";
}

// An HTTP field name is one or more token characters.
const HEADER_TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

// The `x-mcp-header` annotations of one input schema, or the reason they make the tool invalid.
// An annotation must sit on a primitive parameter that a chain of `properties` keys reaches from the root.
/** @param {unknown} schema @returns {Mirrored[] | string} */
export function mirroredParams(schema) {
  /** @type {Mirrored[]} */
  const found = [];
  const seen = new Set();
  // A null path marks a node that no chain of `properties` keys reaches.
  /** @param {unknown} node @param {string[] | null} path @returns {string | null} */
  const walk = (node, path) => {
    if (Array.isArray(node)) {
      for (const item of node) { const reason = walk(item, null); if (reason) return reason; }
      return null;
    }
    if (!record(node)) return null;
    const object = /** @type {Record<string, unknown>} */ (node);
    const mark = object["x-mcp-header"];
    if (mark !== undefined) {
      if (path === null || path.length === 0) return "x-mcp-header outside a properties chain";
      if (typeof mark !== "string" || !HEADER_TOKEN.test(mark)) return "x-mcp-header is not a header token";
      if (object.type !== "string" && object.type !== "integer" && object.type !== "boolean") return "x-mcp-header on a parameter that is not a string, integer, or boolean";
      if (seen.has(mark.toLowerCase())) return "x-mcp-header names one header twice";
      seen.add(mark.toLowerCase());
      found.push({ name: mark, path });
    }
    for (const [key, value] of Object.entries(object)) {
      if (key === "x-mcp-header") continue;
      if (key === "properties" && path !== null && record(value)) {
        for (const [property, child] of Object.entries(/** @type {Record<string, unknown>} */ (value))) { const reason = walk(child, [...path, property]); if (reason) return reason; }
      } else {
        const reason = walk(value, null);
        if (reason) return reason;
      }
    }
    return null;
  };
  return walk(schema, []) ?? found;
}

// Mirror each annotated argument into its `Mcp-Param-*` header. An absent or non-primitive value sends no header.
/** @param {Mirrored[]} mirrored @param {Record<string, unknown>} args @returns {Record<string, string>} */
function paramHeaders(mirrored, args) {
  /** @type {Record<string, string>} */
  const headers = {};
  for (const { name, path } of mirrored) {
    /** @type {unknown} */
    let value = args;
    for (const key of path) value = record(value) && Object.hasOwn(/** @type {object} */ (value), key) ? /** @type {Record<string, unknown>} */ (value)[key] : undefined;
    const text = typeof value === "string" ? value : typeof value === "boolean" || Number.isSafeInteger(value) ? String(value) : null;
    if (text !== null) headers["mcp-param-" + name.toLowerCase()] = headerValue(text);
  }
  return headers;
}

// The message for a wrong entry, or null. A missing variable shows later, when the server starts.
/** @param {ServerConfig} config @returns {string | null} */
function checkConfig(config) {
  if (config.timeout !== undefined && (!Number.isSafeInteger(config.timeout) || config.timeout <= 0)) return "timeout must be a positive integer of milliseconds";
  if (config.enabled !== undefined && typeof config.enabled !== "boolean") return "enabled must be a boolean";
  if (config.alwaysLoad !== undefined && typeof config.alwaysLoad !== "boolean") return "alwaysLoad must be a boolean";
  return null;
}

/** @typedef {{ name: string, description: string, input_schema: string }} ToolAddition */

// The name weighs most; the description and the argument names and descriptions weigh one each per term.
/** @param {ToolDefinition} definition @param {string[]} wanted @returns {number} */
function score(definition, wanted) {
  const name = definition.name.toLowerCase();
  const description = definition.description.toLowerCase();
  const properties = /** @type {Record<string, { description?: unknown }> | undefined} */ (definition.parameters.properties);
  const params = properties === undefined ? "" : Object.entries(properties).map(([key, value]) => key + " " + (typeof value?.description === "string" ? value.description : "")).join(" ").toLowerCase();
  let total = 0;
  for (const term of wanted) {
    if (name.includes(term)) total += 3;
    if (description.includes(term)) total += 1;
    if (params.includes(term)) total += 1;
  }
  return total;
}

// The search reads the whole catalog here; the request declares only what it loads, so the context stays small.
/** @param {Server[]} servers @param {unknown} args @returns {string | { __yuke_result: true, text: string, extra: { tools_added: ToolAddition[] } }} */
function searchCatalog(servers, args) {
  const { query, server: only, limit: asked } = /** @type {{ query?: unknown, server?: unknown, limit?: unknown }} */ (record(args) ? args : {});
  if (typeof query !== "string" || query.trim() === "") throw new Error("query must be a nonempty string");
  if (query.length > QUERY_MAX) throw new Error("query must be at most " + QUERY_MAX + " characters");
  if (only !== undefined && typeof only !== "string") throw new Error("server must be a string");
  if (asked !== undefined && (typeof asked !== "number" || !Number.isSafeInteger(asked) || asked < 1 || asked > LIMIT_MAX)) throw new Error("limit must be an integer from 1 to " + LIMIT_MAX);
  const limit = asked === undefined ? LIMIT_DEFAULT : asked;
  const wanted = query.toLowerCase().split(/[^a-z0-9]+/).filter((term) => term.length > 1);
  /** @type {{ server: string, definition: ToolDefinition, score: number }[]} */
  const hits = [];
  const connected = [];
  for (const server of servers) {
    if (server.state !== "connected") continue;
    connected.push(server.name);
    if (only !== undefined && server.name !== only) continue;
    for (const definition of server.definitions) {
      const total = score(definition, wanted);
      if (total > 0) hits.push({ server: server.name, definition, score: total });
    }
  }
  hits.sort((a, b) => b.score - a.score || (a.definition.name < b.definition.name ? -1 : 1));
  // A hit far below the best match is noise from a common word, and each loaded tool costs context.
  const best = hits[0];
  const floor = best === undefined ? 0 : Math.ceil(best.score / 2);
  while ((hits.at(-1)?.score ?? floor) < floor) hits.pop();
  if (hits.length === 0) return "No MCP tool matches " + JSON.stringify(query) + ". Connected servers: " + (connected.length ? connected.join(", ") : "none") + ".";
  /** @type {string[]} */
  const lines = [];
  /** @type {ToolAddition[]} */
  const added = [];
  let bytes = 0;
  for (const hit of hits.slice(0, limit)) {
    const description = hit.definition.description.slice(0, DESCRIPTION_MAX);
    // An eager tool is in the context already, so only a deferred one is loaded.
    const schema = hit.definition.defer === true ? JSON.stringify(hit.definition.parameters) : "";
    const line = hit.definition.name + " (" + hit.server + "): " + description + (schema.length > SCHEMA_MAX ? " [not loaded: the input schema is too large]" : "");
    if (bytes + line.length > RESULT_MAX) break;
    bytes += line.length + 1;
    lines.push(line);
    if (schema !== "" && schema.length <= SCHEMA_MAX) added.push({ name: hit.definition.name, description, input_schema: schema });
  }
  return { __yuke_result: true, text: "Found " + lines.length + " MCP tool" + (lines.length === 1 ? "" : "s") + ":\n" + lines.join("\n"), extra: { tools_added: added } };
}

// A trust record keeps a digest of the server identity, so a changed command or URL asks again.
/** @param {string} name @param {string} identity @returns {boolean | undefined} */
function readTrust(name, identity) {
  const text = mcpNative.readRecord("mcp-trust", name);
  if (text === undefined) return undefined;
  let saved;
  try { saved = JSON.parse(text); } catch { return undefined; }
  return record(saved) && saved.identity === sha256(identity) && typeof saved.approved === "boolean" ? saved.approved : undefined;
}

/** @param {string} name @param {string} identity @param {boolean} approved */
function writeTrust(name, identity, approved) {
  mcpNative.writeRecord("mcp-trust", name, JSON.stringify({ approved, identity: sha256(identity) }));
}

class Server {
  /** @param {string} name @param {ServerConfig} config @param {Limits} limits @param {boolean} trusted @param {Context} ctx */
  constructor(name, config, limits, trusted, ctx) {
    this.name = name;
    this.config = config;
    this.limits = limits;
    this.ctx = ctx;
    this.workspace = !trusted;
    /** @type {Endpoint | null} */
    this.endpoint = null;
    /** @type {ServerState} */
    this.state = "pending";
    this.error = "";
    // The plugin swaps its search tool when a server or its catalog changes.
    this.onChange = () => {};
    /** @type {"" | "modern" | "legacy"} */
    this.era = "";
    this.instructions = "";
    /** @type {Promise<void>} The startup promise resolves within the startup limit. */
    this.started = Promise.resolve();
    this.hasTools = false;
    // The server promises tool list changes; a modern one delivers them on a subscription stream.
    this.listChanged = false;
    // The server acknowledged a subscription without the tool list, so no stream opens again.
    this.listenRefused = false;
    this.listenTimer = 0;
    // The id of the open subscription request, so a refused filter can close its stream.
    this.listenId = 0;
    /** @type {Transport | null} */
    this.transport = null;
    // The last transport keeps its diagnostics for the row after it closes.
    /** @type {Transport | null} */
    this.last = null;
    this.nextId = 1;
    /** @type {Map<number, Waiting>} */
    this.waiting = new Map();
    /** @type {(() => void)[]} */
    this.disposers = [];
    /** @type {ToolDefinition[]} */
    this.definitions = [];
    // The server's own tool names, sorted.
    /** @type {string[]} */
    this.names = [];
    // The last `WWW-Authenticate` challenge; a sign-in reads the authorization server from it.
    this.challenge = "";
    // The mirrored parameters of each HTTP tool, and the tools an invalid annotation dropped.
    /** @type {Map<string, Mirrored[]>} */
    this.mirrors = new Map();
    /** @type {string[]} */
    this.dropped = [];
    this.refreshing = false;
    this.refreshAgain = false;
    const type = config.type ?? (config.url ? "http" : "stdio");
    const problem = checkConfig(config);
    if (config.enabled === false) this.state = "disabled";
    else if (problem !== null) this.fail("failed", problem);
    else if (!trusted) this.state = "untrusted";
    if (this.state !== "pending" && this.state !== "untrusted") return;
    try { this.endpoint = endpointFor(config, type); } catch (error) {
      this.fail("failed", errorText(error));
      return;
    }
    if (!trusted) {
      try {
        const approved = readTrust(name, this.endpoint.identity);
        if (approved === true) this.state = "pending";
        else if (approved === false) this.fail("disabled", "not trusted");
      } catch (error) { this.error = errorText(error); }
    }
  }

  /** @param {ServerState} state @param {string} message */
  fail(state, message) {
    // A late line or exit after a stop changes nothing.
    if (this.state === "stopped") return;
    clearTimeout(this.listenTimer);
    this.state = state;
    this.error = message;
    this.undefineTools();
    this.settleAll(message);
    const transport = this.transport;
    this.transport = null;
    if (transport) transport.close().catch(() => {});
    this.onChange();
  }

  /** @param {string} reason */
  settleAll(reason) {
    for (const id of [...this.waiting.keys()]) this.settle(id, undefined, new Error(reason));
  }

  /** @returns {Promise<void>} */
  start() {
    this.started = this.connect();
    return this.started;
  }

  /** @returns {Promise<void>} */
  async connect() {
    this.state = "connecting";
    const deadline = Date.now() + this.limits.startupMs;
    try {
      this.open();
      await this.handshake(deadline);
      if (this.hasTools) await this.refresh(deadline);
      if (this.state === "connecting") {
        this.state = "connected";
        if (this.refreshAgain) this.refreshTools();
        if (this.era === "modern" && this.listChanged) this.listen();
      }
    } catch (error) {
      if (this.state === "connecting") this.refuse(error);
    }
    this.onChange();
  }

  // A 401 that no stored grant fixes asks for a sign-in; any other error fails the server.
  /** @param {unknown} error */
  refuse(error) {
    if (error instanceof Error && "signIn" in error) {
      this.challenge = String(error.signIn);
      // No handshake answered, so the era is unknown.
      this.era = "";
      this.fail("needs auth", "run /mcp-login " + this.name);
    } else this.fail("failed", errorText(error));
  }

  open() {
    const endpoint = this.endpoint;
    if (!endpoint) throw new Error("the MCP execution configuration is unavailable");
    // Ignore callbacks from an older transport after close or replacement.
    /** @type {Transport} */
    const transport = endpoint.open({
      message: (text) => this.transport === transport ? this.receive(text) : undefined,
      closed: (reason, options) => {
        if (this.transport !== transport) return;
        this.transport = null;
        this.settleAll(reason);
        const connected = this.state === "connected";
        if (connected || this.state === "connecting") this.refuse(options?.signIn !== undefined ? Object.assign(new Error(reason), { signIn: options.signIn }) : new Error(reason));
        // A connected server that ended its session gets a new one; a handshake still runs its own attempt.
        if (connected && options?.reconnect) this.start();
      },
    });
    this.transport = transport;
    this.last = transport;
  }

  // Answer the id of the request this text settles, so a transport knows its exchange ended.
  /** @param {string} text @returns {number | undefined} */
  receive(text) {
    let message;
    try { message = decodeMessage(text); } catch (error) { this.fail("failed", errorText(error)); return undefined; }
    if (typeof message.method !== "string") {
      if (typeof message.id !== "number") return undefined;
      const slot = this.waiting.get(message.id);
      if (slot) slot.bytes = text.length;
      const error = message.error === undefined ? undefined : Object.assign(new Error(message.error.message), { code: message.error.code, data: message.error.data });
      this.settle(message.id, message.result, error);
      return message.id;
    }
    // The legacy era lets a server ask the client. A ping gets its empty answer; every other request is refused.
    if (message.id !== undefined && message.id !== null) {
      const answer = message.method === "ping" ? { jsonrpc: "2.0", id: message.id, result: {} } : { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "yuke answers no server requests" } };
      this.send(answer).catch(() => {});
      return undefined;
    }
    if (message.method === "notifications/tools/list_changed" && this.hasTools) this.refreshTools();
    else if (message.method === "notifications/progress") this.progress(message.params);
    // The acknowledgment names the subset the server honors; a stream without tool changes serves nothing, so it closes.
    else if (message.method === "notifications/subscriptions/acknowledged" && message.params?.notifications?.toolsListChanged !== true) {
      this.listenRefused = true;
      if (this.listenId !== 0) this.transport?.cancel(this.listenId, "the server honors no tool list changes");
    }
    return undefined;
  }

  /** @param {Record<string, unknown>} message @param {Record<string, string>} [headers] @returns {Promise<void>} */
  send(message, headers) {
    if (!this.transport) return Promise.reject(new Error("the server is not running"));
    return this.transport.send(message, headers);
  }

  // A handshake request is not cancelable: the legacy rules forbid a cancel of `initialize`.
  // A progress-enabled request uses its id as the token. Each larger report resets the timer, up to a cap.
  /** @param {string} method @param {Record<string, unknown>} params @param {{ timeoutMs: number, signal?: CancellationSignal, cancelable?: boolean, received?: { bytes: number }, headers?: Record<string, string> | undefined, progress?: ((report: Record<string, unknown>) => void) | undefined }} options @returns {Promise<any>} */
  request(method, params, { timeoutMs, signal, cancelable = true, received, headers, progress }) {
    if (signal?.aborted) return Promise.reject(new Error("the call was canceled"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      let timer = 0;
      /** @param {number} ms */
      const arm = (ms) => {
        clearTimeout(timer);
        timer = setTimeout(() => this.cancel(id, "the request timed out"), Math.max(1, ms));
      };
      arm(timeoutMs);
      const cap = Date.now() + timeoutMs * PROGRESS_CAP;
      let last = -Infinity;
      const listener = signal === undefined ? 0 : cancellation.listen(signal, () => this.cancel(id, "the call was canceled"));
      /** @type {Waiting} */
      const slot = { bytes: 0, cancelable, resolve, reject, done: () => { if (received) received.bytes = this.waiting.get(id)?.bytes ?? 0; clearTimeout(timer); if (listener !== 0) cancellation.unlisten(listener); } };
      // A report must rise, so a repeated or falling value keeps the timer as it is.
      if (progress) slot.progress = (value, report) => {
        if (value <= last) return;
        last = value;
        arm(Math.min(timeoutMs, cap - Date.now()));
        progress(report);
      };
      this.waiting.set(id, slot);
      /** @type {Record<string, unknown>} */
      const meta = this.era === "modern" ? { ...META } : {};
      if (progress) meta.progressToken = id;
      const sent = Object.keys(meta).length === 0 ? params : { ...params, _meta: meta };
      this.send({ jsonrpc: "2.0", id, method, params: sent }, headers).catch((error) => this.settle(id, undefined, error));
    });
  }

  // Route one progress report to the request whose id is its token. A report for no active request changes nothing.
  /** @param {unknown} params */
  progress(params) {
    if (!record(params)) return;
    const { progressToken: token, progress: value } = /** @type {Record<string, unknown>} */ (params);
    if (typeof token !== "number" || typeof value !== "number" || !Number.isFinite(value)) return;
    this.waiting.get(token)?.progress?.(value, /** @type {Record<string, unknown>} */ (params));
  }

  // The listen request carries modern tool-list changes. A broken stream retries. A graceful result, a refusal, or a new transport stops the loop.
  async listen() {
    const transport = this.transport;
    let delay = LISTEN_RETRY_MS;
    while (this.state === "connected" && this.transport === transport && transport && !this.listenRefused) {
      const id = this.nextId++;
      this.listenId = id;
      try {
        await transport.send({ jsonrpc: "2.0", id, method: "subscriptions/listen", params: { _meta: META, notifications: { toolsListChanged: true } } });
        // STDIO keeps the subscription on the pipe. HTTP ends a graceful subscription with a result.
        return;
      } catch (error) {
        if (this.transport !== transport) return;
        // A sign-in or an HTTP refusal does not heal with time, so only a broken stream retries.
        if (error instanceof Error && "signIn" in error) return this.refuse(error);
        if (error instanceof Error && ("status" in error || "code" in error)) return;
      } finally {
        this.listenId = 0;
      }
      await new Promise((resolve) => { this.listenTimer = setTimeout(() => resolve(undefined), delay); });
      delay = Math.min(delay * 2, LISTEN_RETRY_MAX_MS);
    }
  }

  /** @param {number} id @param {unknown} result @param {Error} [error] */
  settle(id, result, error) {
    const slot = this.waiting.get(id);
    if (!slot) return;
    slot.done();
    this.waiting.delete(id);
    if (error) slot.reject(error); else slot.resolve(result);
  }

  // Tell the server to stop the work, then answer the caller; a late result finds nobody.
  /** @param {number} id @param {string} reason */
  cancel(id, reason) {
    const slot = this.waiting.get(id);
    if (!slot) return;
    if (slot.cancelable) this.transport?.cancel(id, reason);
    this.settle(id, undefined, new Error(reason));
  }

  /** @param {any} answer */
  accept(answer) {
    // The answer comes from the server, so its shape is checked here.
    const capabilities = answer.capabilities;
    if (!record(capabilities)) invalid("server capabilities");
    const tools = capabilities.tools;
    if (tools !== undefined && (!record(tools) || (tools.listChanged !== undefined && typeof tools.listChanged !== "boolean"))) invalid("tool capabilities");
    this.hasTools = tools !== undefined;
    this.listChanged = tools?.listChanged === true;
    this.instructions = typeof answer.instructions === "string" ? answer.instructions.slice(0, INSTRUCTIONS_MAX) : "";
  }

  // Probe the modern era first. A modern answer settles it; a version error that names a legacy version, any other error, or a timeout means a legacy server.
  /** @param {number} deadline */
  async handshake(deadline) {
    this.era = "modern";
    let found;
    try {
      found = await this.request("server/discover", {}, { timeoutMs: Math.min(deadline - Date.now(), this.limits.startupMs / 2), cancelable: false });
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === UNSUPPORTED_VERSION) {
        const supported = /** @type {any} */ (error).data?.supported;
        if (!Array.isArray(supported) || !supported.some((version) => LEGACY_KNOWN.includes(version))) throw new Error("the server supports no protocol version this client speaks");
      } else if (this.state !== "connecting" || !this.transport || (error instanceof Error && (("code" in error && error.code === HEADER_MISMATCH) || "signIn" in error))) throw error;
      this.era = "legacy";
    }
    if (this.era === "modern") {
      complete(found, true);
      const versions = found.supportedVersions;
      if (!Array.isArray(versions) || !versions.every((/** @type {any} */ value) => typeof value === "string")) return invalid("supported versions");
      if (versions.includes(MODERN)) return this.accept(found);
      if (!versions.some((version) => LEGACY_KNOWN.includes(version))) throw new Error("the server supports no protocol version this client speaks");
      this.era = "legacy";
    }
    const init = await this.request("initialize", { protocolVersion: LEGACY, capabilities: {}, clientInfo: CLIENT }, { timeoutMs: deadline - Date.now(), cancelable: false });
    complete(init, false);
    if (!LEGACY_KNOWN.includes(init.protocolVersion)) throw new Error("the server answered initialize with an unknown protocol version");
    this.accept(init);
    if (!record(init.serverInfo) || typeof init.serverInfo.name !== "string" || typeof init.serverInfo.version !== "string") return invalid("initialize result");
    this.transport?.negotiated(init.protocolVersion);
    await this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  }

  // Coalesce a burst into the active refresh and at most one follow-up pass.
  async refreshTools() {
    this.refreshAgain = true;
    if (this.refreshing) return;
    this.refreshing = true;
    try {
      while (this.refreshAgain && this.state === "connected") {
        this.refreshAgain = false;
        try { await this.refresh(Date.now() + this.limits.startupMs); }
        catch (error) { this.error = errorText(error); }
      }
    } finally { this.refreshing = false; }
    this.onChange();
  }

  // List every page, then swap the tool set. The run loadout is chosen once, so a change lands on the next run.
  /** @param {number} deadline */
  async refresh(deadline) {
    if (this.state !== "connecting" && this.state !== "connected") return;
    /** @type {{ name: string, description?: string, title?: string, inputSchema: Record<string, unknown> }[]} */
    const tools = [];
    const names = new Set();
    const cursors = new Set();
    const received = { bytes: 0 };
    let catalog_bytes = 0;
    /** @type {string | undefined} */
    let cursor;
    for (let page = 0; ; page++) {
      if (page === MAX_PAGES) return invalid("tool page limit");
      const answer = await this.request("tools/list", cursor === undefined ? {} : { cursor }, { timeoutMs: deadline - Date.now(), received });
      complete(answer, this.era === "modern");
      // UTF-8 uses at most three bytes per UTF-16 unit, so this bound needs no wire copy.
      catalog_bytes += received.bytes * 3;
      if (catalog_bytes > MAX_CATALOG_BYTES) return invalid("catalog size limit");
      if (!Array.isArray(answer.tools)) return invalid("tool list");
      if (tools.length + answer.tools.length > MAX_TOOLS) return invalid("tool count limit");
      for (const tool of answer.tools) {
        validateTool(tool);
        if (names.has(tool.name)) return invalid("duplicate tool name");
        names.add(tool.name);
        tools.push(tool);
      }
      cursor = answer.nextCursor;
      if (cursor === undefined) break;
      if (typeof cursor !== "string" || cursor === "" || cursors.has(cursor)) return invalid("tool cursor");
      cursors.add(cursor);
    }
    tools.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    // A server that stopped or failed while the list was in flight defines nothing.
    if (this.state !== "connecting" && this.state !== "connected") return;
    /** @type {ToolDefinition[]} */
    const definitions = [];
    const used = new Set();
    /** @type {Map<string, Mirrored[]>} */
    const mirrors = new Map();
    /** @type {string[]} */
    const dropped = [];
    /** @type {string[]} */
    const kept = [];
    for (const tool of tools) {
      // An HTTP client must drop a tool whose header annotation is invalid, and keep the rest.
      if (this.endpoint?.mirrorsParams) {
        const mirrored = mirroredParams(tool.inputSchema);
        if (typeof mirrored === "string") { dropped.push(tool.name + " (" + mirrored + ")"); continue; }
        if (mirrored.length !== 0) mirrors.set(tool.name, mirrored);
      }
      kept.push(tool.name);
      const base = toolName(this.name, tool.name);
      let name = base;
      for (let n = 2; used.has(name); n++) name = base.slice(0, NAME_MAX - 1 - String(n).length) + "_" + n;
      used.add(name);
      definitions.push({
        name,
        description: tool.description || tool.title || "The " + tool.name + " tool of the " + this.name + " MCP server.",
        parameters: tool.inputSchema.properties === undefined ? { ...tool.inputSchema, properties: {} } : tool.inputSchema,
        // A deferred definition stays out of the prompt until a tool search names it; `alwaysLoad` keeps a server eager.
        defer: this.config.alwaysLoad !== true,
        execute: (args, signal, context) => this.call(tool.name, args, signal, context),
      });
    }
    const previous = this.definitions;
    const previous_names = this.names;
    this.undefineTools();
    try {
      this.defineTools(definitions);
      this.names = kept;
      this.mirrors = mirrors;
      this.dropped = dropped;
      this.error = "";
    } catch (error) {
      this.undefineTools();
      this.defineTools(previous);
      this.names = previous_names;
      throw error;
    }
  }

  // This synchronous swap restores the old declarations if native registration refuses a new one.
  /** @param {ToolDefinition[]} definitions */
  defineTools(definitions) {
    for (const definition of definitions) this.disposers.push(this.ctx.tools.define(definition));
    this.definitions = definitions;
  }

  undefineTools() {
    for (const dispose of this.disposers) dispose();
    this.disposers = [];
    this.names = [];
    this.definitions = [];
  }

  /** @param {string} tool @param {unknown} args @param {CancellationSignal} signal @param {ToolContext} context @returns {Promise<string | { __yuke_result: true, text: string, extra: { media: Wire.MediaBlob[] } }>} */
  async call(tool, args, signal, context) {
    if (this.state !== "connected") throw new Error("the MCP server " + this.name + " is " + this.state);
    if (!record(args)) throw new Error("MCP tool arguments must be an object");
    const mirrored = this.mirrors.get(tool);
    const headers = mirrored ? paramHeaders(mirrored, /** @type {Record<string, unknown>} */ (args)) : undefined;
    let result;
    try {
      // Each report shows as one live line; the model reads only the result.
      result = await this.request("tools/call", { name: tool, arguments: args }, { timeoutMs: this.config.timeout ?? this.limits.callMs, signal, headers, progress: (report) => context.output(progressLine(report)) });
    } catch (error) {
      // When refresh fails, end the session and name the sign-in command.
      if (error instanceof Error && "signIn" in error) {
        this.refuse(error);
        throw new Error("the MCP server " + this.name + " needs a sign-in: run /mcp-login " + this.name);
      }
      throw error;
    }
    const { text, images } = toolResult(result, this.era === "modern");
    /** @type {Wire.MediaBlob[]} */
    const media = [];
    // The text line still names an image the store refuses, such as an SVG, so the model knows of it.
    for (const data of images) await client.blobPutData(data).then((blob) => { media.push(blob); }, () => {});
    return media.length === 0 ? text : { __yuke_result: true, text, extra: { media } };
  }

  // Stop at once for the callers, then let the transport shut down.
  /** @returns {Promise<void>} */
  async close() {
    this.state = "stopped";
    this.refreshAgain = false;
    clearTimeout(this.listenTimer);
    this.undefineTools();
    this.settleAll("the MCP server stopped");
    this.onChange();
    const transport = this.transport;
    this.transport = null;
    if (transport) await transport.close();
  }

  /** @returns {[string, string]} */
  row() {
    /** @type {string[]} */
    const parts = [this.state];
    if (this.era) parts.push(this.era);
    if (this.state === "connected") parts.push(this.names.length === 0 ? "no tools" : this.names.length + (this.names.length === 1 ? " tool: " : " tools: ") + this.names.join(", "));
    if (this.state === "connected" && this.dropped.length !== 0) parts.push("dropped: " + this.dropped.join(", "));
    if (this.error) parts.push(this.error);
    if (this.last) parts.push(...this.last.diagnostics(this.state === "failed"));
    return [this.name, parts.join(" · ")];
  }
}

// A missing file is the normal case. Any other failure is a problem the panel shows.
/** @param {string} path @param {string[]} problems @returns {Promise<Record<string, ServerConfig>>} */
async function readServers(path, problems) {
  let text;
  try { text = await fs.readFile(path); } catch (error) {
    const message = errorText(error);
    if (message !== "the path does not exist") problems.push(path + ": " + message);
    return {};
  }
  try {
    const servers = JSON.parse(text)?.mcpServers;
    if (!record(servers)) throw new Error("mcpServers must be an object");
    // Each entry is checked where its server starts, so a bad entry fails only that server.
    return /** @type {Record<string, ServerConfig>} */ (servers);
  } catch (error) {
    problems.push(path + ": " + errorText(error));
    return {};
  }
}

/** @typedef {Plugin & { rows(): [string, string][], resetTrust(): Promise<void>, login(name: string, open?: (url: string) => Promise<void> | void): Promise<void>, logout(name: string): Promise<void> }} McpPlugin */

/** @param {McpOptions} [options] @returns {McpPlugin} */
export function mcp(options = {}) {
  /** @type {Limits} */
  const limits = { startupMs: options.startupMs ?? 10_000, callMs: options.callMs ?? 60_000 };
  if (!Number.isSafeInteger(limits.startupMs) || limits.startupMs <= 0 || !Number.isSafeInteger(limits.callMs) || limits.callMs <= 0) throw new TypeError("MCP timeouts must be positive integer milliseconds");
  /** @type {Server[]} */
  const servers = [];
  /** @type {string[]} */
  const problems = [];
  let asked = false;
  // Start a server again as a new instance, with the same trust; a fresh endpoint holds no cached token.
  /** @param {number} index */
  const restart = async (index) => {
    const server = /** @type {Server} */ (servers[index]);
    await server.close();
    const fresh = new Server(server.name, server.config, limits, !server.workspace, server.ctx);
    fresh.onChange = server.onChange;
    servers[index] = fresh;
    if (fresh.state === "pending") fresh.start();
    return fresh;
  };
  /** @param {string} name @returns {number} */
  const remoteIndex = (name) => {
    const index = servers.findIndex((server) => server.name === name);
    if (index < 0) throw new Error("no MCP server is named " + name);
    const endpoint = /** @type {Server} */ (servers[index]).endpoint;
    if (!endpoint?.signsIn) throw new Error("the MCP server " + name + " takes no sign-in");
    return index;
  };
  /** @type {McpPlugin} */
  const plugin = {
    name: "mcp",
    /** @param {Context} ctx */
    async apply(ctx) {
      // A restart replaces a server in the list, so the release closes the servers the list holds at unload.
      ctx.own(() => Promise.all(servers.map((server) => server.close())));
      // The first definition of a name wins: index.js, then the user file, then the workspace file, which is not trusted yet.
      /** @type {[Record<string, ServerConfig>, boolean][]} */
      const sources = [[options.servers ?? {}, true]];
      try {
        const user = mcpNative.configPath();
        if (user !== undefined) sources.push([await readServers(user, problems), true]);
      } catch (error) { problems.push(errorText(error)); }
      sources.push([await readServers(WORKSPACE_FILE, problems), false]);
      if (!ctx.alive) return;
      for (const [configs, trusted] of sources) for (const [name, config] of Object.entries(configs)) {
        if (servers.some((server) => server.name === name)) continue;
        if (!record(config)) { problems.push(name + ": the server entry must be an object"); continue; }
        servers.push(new Server(name, config, limits, trusted, ctx));
      }
      /** @type {(() => void) | null} */
      let disposeSearch = null;
      let searchDescription = "";
      // One search tool covers every connected server. Its description names them, so the model knows when to search.
      const refreshSearchTool = () => {
        if (!ctx.alive) return;
        const connected = servers.filter((server) => server.state === "connected");
        const description = connected.length === 0 ? "" : ("Search the MCP tool catalog by keywords and load the matching tools. Servers: " + connected.map((server) => server.name + (server.instructions ? " (" + server.instructions + ")" : "")).join("; ") + ".").slice(0, SEARCH_DESCRIPTION_MAX);
        if (description === searchDescription) return;
        if (disposeSearch) { disposeSearch(); disposeSearch = null; }
        searchDescription = "";
        if (description === "") return;
        // A refused name leaves no search tool; the next change tries again.
        try { disposeSearch = ctx.tools.define({
          name: SEARCH_TOOL,
          description,
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "Keywords that describe the tool you need." },
              server: { type: "string", description: "Search one server only." },
              limit: { type: "integer", description: "How many tools to load, 1 to " + LIMIT_MAX + ". The default is " + LIMIT_DEFAULT + "." },
            },
            required: ["query"],
            additionalProperties: false,
          },
          execute: async (args) => searchCatalog(servers, args),
        }); } catch (error) {
          problems.push(SEARCH_TOOL + ": " + errorText(error));
          return;
        }
        searchDescription = description;
      };
      for (const server of servers) server.onChange = refreshSearchTool;
      for (const server of servers) if (server.state === "pending") server.start();

      // The loadout follows this hook, so trust prompts and server startup finish before it.
      ctx.hook("tools.select", async () => {
        if (!asked) {
          asked = true;
          for (const server of servers) {
            if (server.state !== "untrusted") continue;
            if (!ctx.interaction.interactive) { server.fail("disabled", "not trusted"); continue; }
            const endpoint = /** @type {Endpoint} */ (server.endpoint);
            const ok = await ctx.interaction.confirm("Start the MCP server " + server.name + "?", WORKSPACE_FILE + " " + endpoint.describe + "\nRemember this decision for this workspace and server configuration.");
            if (ok === undefined || !ctx.alive || server.state !== "untrusted") continue;
            try { writeTrust(server.name, endpoint.identity, ok); }
            catch (error) { problems.push(server.name + ": " + errorText(error)); }
            if (ok) server.start(); else server.fail("disabled", "not trusted");
          }
        }
        const starting = servers.filter((server) => server.state === "connecting");
        if (starting.length !== 0) await Promise.all(starting.map((server) => server.started));
      });

      ctx.inject(["tui"], (ctx) => {
        ctx.tui.command(null, {
          "mcp:show": () => showInfo(ctx, "mcp", plugin.rows()),
          "mcp:reset-trust": () => plugin.resetTrust(),
          "mcp:login": (/** @type {string | undefined} */ query) => {
            // Without a name, the first server that waits for a sign-in is the one.
            const name = query?.trim() || servers.find((server) => server.state === "needs auth")?.name;
            if (!name) { notice.show("no MCP server needs a sign-in"); return; }
            notice.show("MCP " + name + ": sign in in the browser");
            plugin.login(name).then(() => notice.show("MCP " + name + ": signed in"), (error) => notice.show("MCP " + name + ": " + errorText(error)));
          },
          "mcp:logout": (/** @type {string | undefined} */ query) => {
            const name = query?.trim();
            if (!name) { notice.show("name the MCP server to sign out of"); return; }
            plugin.logout(name).then(() => notice.show("MCP " + name + ": signed out"), (error) => notice.show("MCP " + name + ": " + errorText(error)));
          },
        }, {
          "mcp:show": { title: "MCP", description: "show the MCP servers and their tools", slash: "mcp" },
          "mcp:reset-trust": { title: "Reset MCP trust", description: "forget this workspace’s MCP server decisions", slash: "mcp-reset-trust" },
          "mcp:login": { title: "MCP sign-in", description: "sign in to an MCP server over OAuth", slash: "mcp-login", args: true },
          "mcp:logout": { title: "MCP sign-out", description: "forget the sign-in of an MCP server", slash: "mcp-logout", args: true },
        });
      });
    },
    // Sign in, then start the server again when it waited for the sign-in; a running server keeps its session.
    async login(name, open = openUrl) {
      const index = remoteIndex(name);
      const server = /** @type {Server} */ (servers[index]);
      const url = /** @type {string} */ (server.endpoint?.url);
      const oauth = server.config.oauth;
      await signIn(url, { challenge: server.challenge, config: oauth ? oauth : {}, open });
      if (server.state === "needs auth" || server.state === "failed") await restart(index);
    },
    // Forget the grant and start again, so the server asks for a new sign-in.
    async logout(name) {
      const index = remoteIndex(name);
      forget(/** @type {string} */ (/** @type {Server} */ (servers[index]).endpoint?.url));
      if (/** @type {Server} */ (servers[index]).state !== "untrusted") await restart(index);
    },
    // A reset server starts over as a new, untrusted instance.
    async resetTrust() {
      for (const [index, server] of servers.entries()) {
        if (!server.workspace) continue;
        try { mcpNative.removeRecord("mcp-trust", server.name); } catch (error) {
          problems.push(server.name + ": " + errorText(error));
          continue;
        }
        // The record is gone, so the fresh instance waits for trust and does not start.
        if (server.endpoint) await restart(index);
      }
      asked = false;
    },
    /** @returns {[string, string][]} */
    rows() {
      const rows = servers.map((server) => server.row());
      for (const problem of problems) rows.push(["config", problem]);
      return rows.length ? rows : [["mcp", "no servers configured"]];
    },
  };
  return plugin;
}
