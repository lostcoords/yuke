// yuke:mcp — MCP servers as yuke tools. `.mcp.json` names them; `yuke:mcp-transport` carries each one.
import { mcpState } from "yuke:mcp-native";
import * as cancellation from "yuke:cancellation-native";
import { fs } from "yuke:fs";
import { showInfo } from "yuke:info-panel";
import { checkTransport, endpointFor } from "yuke:mcp-transport";
import { client } from "yuke:client";

/** @import { Context } from "yuke:ext" */
/** @import { Plugin, ToolDefinition } from "./types/ext.js" */
/** @typedef {import("yuke:cancellation-native").CancellationSignal} CancellationSignal */
/** @typedef {import("yuke:mcp-transport").ServerConfig} ServerConfig */
/** @typedef {import("yuke:mcp-transport").Transport} Transport */
/** @typedef {import("yuke:mcp-transport").Endpoint} Endpoint */
/** @typedef {{ servers?: Record<string, ServerConfig>, startupMs?: number, callMs?: number }} McpOptions */
/** @typedef {{ startupMs: number, callMs: number }} Limits */
/** @typedef {"pending" | "untrusted" | "connecting" | "connected" | "failed" | "disabled" | "stopped"} ServerState */
/** @typedef {{ resolve: (value: any) => void, reject: (error: Error) => void, done: () => void, bytes: number, cancelable: boolean }} Waiting */

const WORKSPACE_FILE = ".mcp.json";
const MODERN = "2026-07-28";
const LEGACY = "2025-11-25";
// The legacy versions this client can serve. A server that answers another one gets no requests.
const LEGACY_KNOWN = ["2024-11-05", "2025-03-26", "2025-06-18", LEGACY];
const UNSUPPORTED_VERSION = -32022;
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
// One result attaches at most this many images, as one input does.
const MAX_IMAGES = 8;
// A text result shares this empty list, so it allocates none.
const NO_IMAGES = Object.freeze(/** @type {string[]} */ ([]));
// A result above this reaches the model cut, with a marker that names the missing part.
const MAX_RESULT_CHARS = 100_000;

/** @param {unknown} error @returns {string} */
const errorText = (error) => (error instanceof Error ? error.message : String(error));

/** @param {string} text @returns {number} */
function fnv(text) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) hash = Math.imul(hash ^ text.charCodeAt(i), 0x01000193) >>> 0;
  return hash;
}

// `mcp_<server>_<tool>` within the provider limit; an overflow keeps a prefix and a stable hash of the whole name.
/** @param {string} server @param {string} tool @returns {string} */
export function toolName(server, tool) {
  const raw = "mcp_" + server + "_" + tool;
  const clean = raw.replace(/[^A-Za-z0-9_-]/g, "_");
  if (clean.length <= NAME_MAX) return clean;
  return clean.slice(0, NAME_MAX - 9) + "_" + fnv(raw).toString(16).padStart(8, "0");
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

/** @param {any} value @returns {boolean} */
function record(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

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

/** @param {any} capabilities @returns {boolean} */
function hasTools(capabilities) {
  if (!record(capabilities)) return invalid("server capabilities");
  if (capabilities.tools === undefined) return false;
  if (!record(capabilities.tools) || (capabilities.tools.listChanged !== undefined && typeof capabilities.tools.listChanged !== "boolean")) return invalid("tool capabilities");
  return true;
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

// The message for a wrong entry, or null. A missing variable shows later, when the server starts.
/** @param {ServerConfig} config @returns {string | null} */
function checkConfig(config) {
  if (config.timeout !== undefined && (!Number.isSafeInteger(config.timeout) || config.timeout <= 0)) return "timeout must be a positive integer of milliseconds";
  if (config.enabled !== undefined && typeof config.enabled !== "boolean") return "enabled must be a boolean";
  if (config.alwaysLoad !== undefined && typeof config.alwaysLoad !== "boolean") return "alwaysLoad must be a boolean";
  return null;
}

/** @param {any} answer @returns {string} */
function instructionsOf(answer) {
  return typeof answer.instructions === "string" ? answer.instructions.slice(0, INSTRUCTIONS_MAX) : "";
}

/** @typedef {{ name: string, description: string, input_schema: string }} ToolAddition */

/** @param {string} text @returns {string[]} */
function terms(text) {
  return text.toLowerCase().split(/[^a-z0-9]+/).filter((term) => term.length > 1);
}

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
  const wanted = terms(query);
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
    this.refreshing = false;
    this.refreshAgain = false;
    const type = config.type ?? (config.url ? "http" : "stdio");
    const problem = checkConfig(config) ?? checkTransport(config, type);
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
        const approved = mcpState.readTrust(name, this.endpoint.identity);
        if (approved === true) this.state = "pending";
        else if (approved === false) this.fail("disabled", "not trusted");
      } catch (error) { this.error = errorText(error); }
    }
  }

  /** @param {ServerState} state @param {string} message */
  fail(state, message) {
    // A late line or exit after a stop changes nothing.
    if (this.state === "stopped") return;
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
      }
    } catch (error) {
      if (this.state === "connecting") this.fail("failed", errorText(error));
    }
    this.onChange();
  }

  open() {
    const endpoint = this.endpoint;
    if (!endpoint) throw new Error("the MCP execution configuration is unavailable");
    /** @type {Transport} */
    const transport = endpoint.open({
      message: (text) => { if (this.transport === transport) this.receive(text); },
      closed: (reason) => {
        if (this.transport !== transport) return;
        this.transport = null;
        this.settleAll(reason);
        if (this.state === "connecting" || this.state === "connected") this.fail("failed", reason);
      },
    });
    this.transport = transport;
    this.last = transport;
  }

  /** @param {string} text */
  receive(text) {
    let message;
    try { message = decodeMessage(text); } catch (error) { this.fail("failed", errorText(error)); return; }
    if (typeof message.method !== "string") {
      if (typeof message.id === "number") {
        const slot = this.waiting.get(message.id);
        if (slot) slot.bytes = text.length;
        const error = message.error === undefined ? undefined : Object.assign(new Error(message.error.message), { code: message.error.code, data: message.error.data });
        this.settle(message.id, message.result, error);
      }
      return;
    }
    // The legacy era lets a server ask the client. A ping gets its empty answer; every other request is refused.
    if (message.id !== undefined && message.id !== null) {
      const answer = message.method === "ping" ? { jsonrpc: "2.0", id: message.id, result: {} } : { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "yuke answers no server requests" } };
      this.send(answer).catch(() => {});
      return;
    }
    if (message.method === "notifications/tools/list_changed" && this.hasTools) this.refreshTools();
  }

  /** @param {Record<string, unknown>} message @returns {Promise<void>} */
  send(message) {
    if (!this.transport) return Promise.reject(new Error("the server is not running"));
    return this.transport.send(message);
  }

  // A handshake request is not cancelable: the legacy rules forbid a cancel of `initialize`.
  /** @param {string} method @param {Record<string, unknown>} params @param {{ timeoutMs: number, signal?: CancellationSignal, cancelable?: boolean, received?: { bytes: number } }} options @returns {Promise<any>} */
  request(method, params, { timeoutMs, signal, cancelable = true, received }) {
    if (signal?.aborted) return Promise.reject(new Error("the call was canceled"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.cancel(id, "the request timed out"), Math.max(1, timeoutMs));
      const listener = signal === undefined ? 0 : cancellation.listen(signal, () => this.cancel(id, "the call was canceled"));
      this.waiting.set(id, { bytes: 0, cancelable, resolve, reject, done: () => { if (received) received.bytes = this.waiting.get(id)?.bytes ?? 0; clearTimeout(timer); if (listener !== 0) cancellation.unlisten(listener); } });
      this.send({ jsonrpc: "2.0", id, method, params: this.era === "modern" ? { ...params, _meta: META } : params }).catch((error) => this.settle(id, undefined, error));
    });
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
    this.hasTools = hasTools(answer.capabilities);
    this.instructions = instructionsOf(answer);
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
      } else if (this.state !== "connecting" || !this.transport) throw error;
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
    for (const tool of tools) {
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
        execute: (args, signal) => this.call(tool.name, args, signal),
      });
    }
    const previous = this.definitions;
    const previous_names = this.names;
    this.undefineTools();
    try {
      this.defineTools(definitions);
      this.names = tools.map((tool) => tool.name);
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

  /** @param {string} tool @param {unknown} args @param {CancellationSignal} signal @returns {Promise<string | { __yuke_result: true, text: string, extra: { media: Wire.MediaBlob[] } }>} */
  async call(tool, args, signal) {
    if (this.state !== "connected") throw new Error("the MCP server " + this.name + " is " + this.state);
    if (!record(args)) throw new Error("MCP tool arguments must be an object");
    const result = await this.request("tools/call", { name: tool, arguments: args }, { timeoutMs: this.config.timeout ?? this.limits.callMs, signal });
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
    return servers;
  } catch (error) {
    problems.push(path + ": " + errorText(error));
    return {};
  }
}

/** @param {McpOptions} [options] @returns {Plugin & { rows(): [string, string][], resetTrust(): Promise<void> }} */
export function mcp(options = {}) {
  /** @type {Limits} */
  const limits = { startupMs: options.startupMs ?? 10_000, callMs: options.callMs ?? 60_000 };
  if (!Number.isSafeInteger(limits.startupMs) || limits.startupMs <= 0 || !Number.isSafeInteger(limits.callMs) || limits.callMs <= 0) throw new TypeError("MCP timeouts must be positive integer milliseconds");
  /** @type {Server[]} */
  const servers = [];
  /** @type {string[]} */
  const problems = [];
  let asked = false;
  /** @type {Plugin & { rows(): [string, string][], resetTrust(): Promise<void> }} */
  const plugin = {
    name: "mcp",
    /** @param {Context} ctx */
    async apply(ctx) {
      // The first definition of a name wins: index.js, then the user file, then the workspace file, which is not trusted yet.
      /** @type {[Record<string, ServerConfig>, boolean][]} */
      const sources = [[options.servers ?? {}, true]];
      try {
        const user = mcpState.configPath();
        if (user !== undefined) sources.push([await readServers(user, problems), true]);
      } catch (error) { problems.push(errorText(error)); }
      sources.push([await readServers(WORKSPACE_FILE, problems), false]);
      if (!ctx.scope.alive) return;
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
        if (!ctx.scope.alive) return;
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
            if (ok === undefined || !ctx.scope.alive || server.state !== "untrusted") continue;
            try { mcpState.writeTrust(server.name, endpoint.identity, ok); }
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
        }, { "mcp:show": { title: "MCP", description: "show the MCP servers and their tools", slash: "mcp" }, "mcp:reset-trust": { title: "Reset MCP trust", description: "forget this workspace’s MCP server decisions", slash: "mcp-reset-trust" } });
      });
    },
    // A reset server starts over as a new, untrusted instance.
    async resetTrust() {
      for (const [index, server] of servers.entries()) {
        if (!server.workspace) continue;
        try { mcpState.resetTrust(server.name); } catch (error) {
          problems.push(server.name + ": " + errorText(error));
          continue;
        }
        if (!server.endpoint) continue;
        await server.close();
        const fresh = new Server(server.name, server.config, limits, false, server.ctx);
        fresh.onChange = server.onChange;
        servers[index] = fresh;
      }
      asked = false;
    },
    async stop() {
      await Promise.all(servers.map((server) => server.close()));
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
