// yuke:mcp — MCP servers over stdio as yuke tools. `.mcp.json` names them; one child process serves each one.
import { fs } from "yuke:fs";
import { env } from "yuke:env";
import { spawn, lines } from "yuke:spawn";
import { showInfo } from "yuke:info-panel";

/** @import { Context } from "yuke:ext" */
/** @import { Plugin } from "./types/ext.js" */
/** @typedef {import("yuke:spawn").ChildProcess} ChildProcess */
/** @typedef {import("yuke:cancellation-native").CancellationSignal} CancellationSignal */
/** @typedef {{ type?: "stdio" | "http" | "sse", command?: string, args?: string[], env?: Record<string, string>, cwd?: string, url?: string, headers?: Record<string, string>, enabled?: boolean, timeout?: number }} ServerConfig */
/** @typedef {{ servers?: Record<string, ServerConfig>, startupMs?: number, callMs?: number }} McpOptions */
/** @typedef {{ startupMs: number, callMs: number }} Limits */
/** @typedef {"pending" | "untrusted" | "connecting" | "connected" | "failed" | "disabled" | "unsupported" | "stopped"} ServerState */
/** @typedef {{ resolve: (value: any) => void, reject: (error: Error) => void, done: () => void }} Waiting */

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
const MAX_PAGES = 100;
const STOP_GRACE_MS = 2000;
// A result above this reaches the model cut, with a marker that names the missing part.
const MAX_RESULT_CHARS = 100_000;
// A signal has no listener, so a pending call reads it on this period.
const POLL_MS = 200;
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

// The model reads text. Every other block becomes a one-line description until media results land.
/** @param {unknown} content @param {unknown} structured @returns {string} */
function contentText(content, structured) {
  /** @type {string[]} */
  const parts = [];
  let hasText = false;
  if (Array.isArray(content)) for (const block of content) {
    if (!block || typeof block !== "object") continue;
    const mime = typeof block.mimeType === "string" ? block.mimeType : "";
    switch (block.type) {
      case "text": if (typeof block.text === "string") { parts.push(block.text); hasText = true; } break;
      case "image": case "audio": parts.push("[" + block.type + " " + mime + ", " + (typeof block.data === "string" ? Math.floor(block.data.length * 3 / 4) : 0) + " bytes]"); break;
      case "resource_link": parts.push("[resource " + String(block.uri) + (typeof block.name === "string" ? " " + block.name : "") + "]"); break;
      case "resource": {
        const resource = block.resource;
        if (resource && typeof resource.text === "string") parts.push(resource.text);
        else parts.push("[resource " + String(resource?.uri) + (resource?.mimeType ? " " + resource.mimeType : "") + "]");
        break;
      }
      default: parts.push("[" + String(block.type) + "]");
    }
  }
  // A server should serialize its structured answer as text too, so the JSON appears only when no text block does.
  if (!hasText && structured !== undefined) parts.push(JSON.stringify(structured));
  const text = parts.join("\n");
  if (text.length <= MAX_RESULT_CHARS) return text;
  return text.slice(0, MAX_RESULT_CHARS) + "\n[truncated " + (text.length - MAX_RESULT_CHARS) + " characters]";
}

// A JSON-RPC error carries its code, so the handshake can tell a refused method from a dead or silent server.
/** @param {unknown} error @returns {Error & { code: number }} */
function rpcError(error) {
  const body = error && typeof error === "object" ? /** @type {{ code?: unknown, message?: unknown }} */ (error) : {};
  return Object.assign(new Error(typeof body.message === "string" ? body.message : "the server answered an error"), { code: typeof body.code === "number" ? body.code : -32603 });
}

// The message for a wrong entry, or null. A missing variable shows later, when the server starts.
/** @param {ServerConfig} config @returns {string | null} */
function checkConfig(config) {
  if (typeof config.command !== "string" || config.command === "") return "command must be a nonempty string";
  if (config.args !== undefined && !(Array.isArray(config.args) && config.args.every((arg) => typeof arg === "string"))) return "args must be an array of strings";
  if (config.env !== undefined && !(config.env && typeof config.env === "object" && Object.values(config.env).every((value) => typeof value === "string"))) return "env must be an object of strings";
  if (config.cwd !== undefined && typeof config.cwd !== "string") return "cwd must be a string";
  if (config.timeout !== undefined && typeof config.timeout !== "number") return "timeout must be a number of milliseconds";
  return null;
}

class Server {
  /** @param {string} name @param {ServerConfig} config @param {Limits} limits @param {boolean} trusted @param {Context} ctx */
  constructor(name, config, limits, trusted, ctx) {
    this.name = name;
    this.config = config;
    this.limits = limits;
    this.ctx = ctx;
    /** @type {ServerState} */
    this.state = "pending";
    this.error = "";
    /** @type {"" | "modern" | "legacy"} */
    this.era = "";
    /** @type {ChildProcess | null} */
    this.child = null;
    this.nextId = 1;
    /** @type {Map<number, Waiting>} */
    this.waiting = new Map();
    /** @type {(() => void)[]} */
    this.disposers = [];
    /** @type {Set<string>} */
    this.tools = new Set();
    // The server's own tool names, in the defined order.
    /** @type {string[]} */
    this.names = [];
    // Lines on stdout that are not JSON-RPC. A server that logs there breaks its own framing.
    this.noise = 0;
    // The last stderr line, for the failure row.
    /** @type {string | undefined} */
    this.stderr = undefined;
    this.refreshing = Promise.resolve();
    const type = config.type ?? (config.url ? "http" : "stdio");
    const problem = checkConfig(config);
    if (config.enabled === false) this.state = "disabled";
    else if (type !== "stdio") this.fail("unsupported", "only stdio servers are supported");
    else if (problem !== null) this.fail("failed", problem);
    else if (!trusted) this.state = "untrusted";
  }

  /** @returns {string} */
  commandLine() {
    return [this.config.command ?? "", ...(this.config.args ?? [])].join(" ");
  }

  /** @param {ServerState} state @param {string} message */
  fail(state, message) {
    this.state = state;
    this.error = message;
    this.undefineTools();
    if (this.child) this.child.kill();
  }

  /** @returns {Promise<void>} */
  async start() {
    this.state = "connecting";
    const deadline = Date.now() + this.limits.startupMs;
    try {
      this.spawnChild();
      await this.handshake(deadline);
      await this.refresh(deadline);
      if (this.state === "connecting") this.state = "connected";
    } catch (error) {
      if (this.state === "connecting") this.fail("failed", errorText(error));
    }
  }

  spawnChild() {
    const config = this.config;
    const argv = [expand(config.command ?? ""), ...(config.args ?? []).map(expand)];
    /** @type {Record<string, string>} */
    const vars = {};
    for (const [key, value] of Object.entries(config.env ?? {})) vars[key] = expand(value);
    const child = spawn(argv, { env: vars, ...(config.cwd !== undefined ? { cwd: expand(config.cwd) } : {}) });
    this.child = child;
    child.onStdout(lines((line) => this.receive(line)));
    child.onStderr(lines((line) => { this.stderr = line; }));
    child.exited.then((exit) => {
      this.child = null;
      const reason = exit.signal != null ? "the server ended on signal " + exit.signal : "the server exited with code " + exit.code;
      for (const id of [...this.waiting.keys()]) this.settle(id, undefined, new Error(reason));
      if (this.state === "connecting" || this.state === "connected") this.fail("failed", reason);
    }, (error) => {
      this.child = null;
      this.fail("failed", "the server did not start: " + errorText(error));
    });
  }

  /** @param {string} line */
  receive(line) {
    let message;
    // A protocol line is one JSON object, so a log line skips the parser.
    if (line[0] !== "{") { this.noise += 1; return; }
    try { message = JSON.parse(line); } catch { this.noise += 1; return; }
    if (!message || typeof message !== "object") { this.noise += 1; return; }
    if (typeof message.method !== "string") {
      if (typeof message.id === "number") this.settle(message.id, message.result, message.error === undefined ? undefined : rpcError(message.error));
      return;
    }
    // The legacy era lets a server ask the client. A ping gets its empty answer; every other request is refused.
    if (message.id !== undefined && message.id !== null) {
      const answer = message.method === "ping" ? { jsonrpc: "2.0", id: message.id, result: {} } : { jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "yuke answers no server requests" } };
      this.send(answer).catch(() => {});
      return;
    }
    if (message.method === "notifications/tools/list_changed") {
      this.refreshing = this.refreshing.then(() => this.refresh(Date.now() + this.limits.startupMs)).catch((error) => { this.error = errorText(error); });
    }
  }

  /** @param {Record<string, unknown>} message @returns {Promise<void>} */
  send(message) {
    if (!this.child) return Promise.reject(new Error("the server is not running"));
    return this.child.write(JSON.stringify(message) + "\n");
  }

  /** @param {string} method @param {Record<string, unknown>} params @param {number} timeoutMs @param {CancellationSignal} [signal] @returns {Promise<any>} */
  request(method, params, timeoutMs, signal) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.cancel(id, "the request timed out"), Math.max(1, timeoutMs));
      const poll = signal === undefined ? undefined : setInterval(() => { if (signal.aborted) this.cancel(id, "the call was canceled"); }, POLL_MS);
      this.waiting.set(id, { resolve, reject, done: () => { clearTimeout(timer); if (poll !== undefined) clearInterval(poll); } });
      this.send({ jsonrpc: "2.0", id, method, params: this.era === "modern" ? { ...params, _meta: META } : params }).catch((error) => this.settle(id, undefined, error));
    });
  }

  /** @param {number} id @param {unknown} result @param {Error} [error] */
  settle(id, result, error) {
    const slot = this.waiting.get(id);
    if (!slot) return;
    this.waiting.delete(id);
    slot.done();
    if (error) slot.reject(error); else slot.resolve(result);
  }

  // Tell the server to stop the work, then answer the caller; a late result finds nobody.
  /** @param {number} id @param {string} reason */
  cancel(id, reason) {
    if (!this.waiting.has(id)) return;
    this.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: id, reason } }).catch(() => {});
    this.settle(id, undefined, new Error(reason));
  }

  // Probe the modern era first. A modern answer or a modern error settles it; any other error or a timeout means a legacy server.
  /** @param {number} deadline */
  async handshake(deadline) {
    this.era = "modern";
    try {
      // The probe takes half the startup budget, so a legacy handshake still has the other half.
      const found = await this.request("server/discover", {}, Math.min(deadline - Date.now(), this.limits.startupMs / 2));
      if (!Array.isArray(found?.supportedVersions) || !found.supportedVersions.includes(MODERN)) throw new Error("the server supports no protocol version this client speaks");
      return;
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === UNSUPPORTED_VERSION) throw new Error("the server supports no protocol version this client speaks");
      if (!this.child) throw error;
    }
    this.era = "legacy";
    const init = await this.request("initialize", { protocolVersion: LEGACY, capabilities: {}, clientInfo: CLIENT }, deadline - Date.now());
    if (!LEGACY_KNOWN.includes(init?.protocolVersion)) throw new Error("the server answered initialize with an unknown protocol version");
    await this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  }

  // List every page, then swap the tool set. The run loadout is chosen once, so a change lands on the next run.
  /** @param {number} deadline */
  async refresh(deadline) {
    /** @type {{ name: string, description?: string, title?: string, inputSchema?: Record<string, unknown> }[]} */
    const tools = [];
    /** @type {string | undefined} */
    let cursor;
    for (let page = 0; page < MAX_PAGES; page++) {
      const answer = await this.request("tools/list", cursor === undefined ? {} : { cursor }, deadline - Date.now());
      if (!Array.isArray(answer?.tools)) throw new Error("the server answered tools/list without tools");
      for (const tool of answer.tools) if (tool && typeof tool.name === "string" && tool.name !== "") tools.push(tool);
      cursor = answer.nextCursor;
      if (typeof cursor !== "string" || cursor === "") break;
    }
    tools.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    // A server that stopped or failed while the list was in flight defines nothing.
    if (this.state !== "connecting" && this.state !== "connected") return;
    this.undefineTools();
    for (const tool of tools) {
      // Two server names that clean to one yuke name get `_2`, `_3`, and so on, as fx does.
      const base = toolName(this.name, tool.name);
      let name = base;
      for (let n = 2; this.tools.has(name); n++) name = base.slice(0, NAME_MAX - 1 - String(n).length) + "_" + n;
      try {
        this.disposers.push(this.ctx.tools.define({
          name,
          description: (typeof tool.description === "string" && tool.description) || (typeof tool.title === "string" && tool.title) || "The " + tool.name + " tool of the " + this.name + " MCP server.",
          parameters: tool.inputSchema && typeof tool.inputSchema === "object" ? tool.inputSchema : { type: "object", properties: {} },
          execute: (args, signal) => this.call(tool.name, args, signal),
        }));
        this.tools.add(name);
        this.names.push(tool.name);
      } catch (error) {
        this.error = name + ": " + errorText(error);
      }
    }
  }

  undefineTools() {
    for (const dispose of this.disposers) dispose();
    this.disposers = [];
    this.tools.clear();
    this.names = [];
  }

  /** @param {string} tool @param {unknown} args @param {CancellationSignal} signal @returns {Promise<string>} */
  async call(tool, args, signal) {
    if (this.state !== "connected") throw new Error("the MCP server " + this.name + " is " + this.state);
    const timeoutMs = typeof this.config.timeout === "number" && this.config.timeout > 0 ? this.config.timeout : this.limits.callMs;
    const result = await this.request("tools/call", { name: tool, arguments: args && typeof args === "object" ? args : {} }, timeoutMs, signal);
    if (result?.resultType === "input_required") throw new Error("the tool asks for input, which this client cannot answer");
    const text = contentText(result?.content, result?.structuredContent);
    if (result?.isError === true) throw new Error(text || "the tool failed");
    return text;
  }

  // The MCP stdio shutdown: stdin EOF, a grace period, then TERM and KILL through `kill`.
  /** @returns {Promise<void>} */
  async close() {
    const child = this.child;
    this.state = "stopped";
    this.undefineTools();
    if (!child) return;
    child.closeStdin();
    let grace = 0;
    const exited = await Promise.race([child.exited.then(() => true, () => true), new Promise((resolve) => { grace = setTimeout(() => resolve(false), STOP_GRACE_MS); })]);
    clearTimeout(grace);
    if (!exited) child.kill();
  }

  /** @returns {[string, string]} */
  row() {
    /** @type {string[]} */
    const parts = [this.state];
    if (this.era) parts.push(this.era);
    if (this.state === "connected") parts.push(this.names.length === 0 ? "no tools" : this.names.length + (this.names.length === 1 ? " tool: " : " tools: ") + this.names.join(", "));
    if (this.error) parts.push(this.error);
    if (this.state === "failed" && this.stderr !== undefined) parts.push("stderr: " + this.stderr);
    if (this.noise) parts.push(this.noise + (this.noise === 1 ? " stray stdout line" : " stray stdout lines"));
    return [this.name, parts.join(" · ")];
  }
}

// `XDG_CONFIG_HOME` or `~/.config`, then the app leaf, as `src/paths.zig` resolves it.
/** @returns {string | undefined} */
function userConfigPath() {
  const xdg = env.get("XDG_CONFIG_HOME");
  const home = env.get("HOME");
  const base = xdg && xdg.startsWith("/") ? xdg : home && home.startsWith("/") ? home + "/.config" : undefined;
  return base === undefined ? undefined : base + "/" + (env.get("YUKE_APPNAME") || "yuke") + "/" + WORKSPACE_FILE;
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
    if (!servers || typeof servers !== "object" || Array.isArray(servers)) throw new Error("mcpServers must be an object");
    return servers;
  } catch (error) {
    problems.push(path + ": " + errorText(error));
    return {};
  }
}

/** @param {McpOptions} [options] @returns {Plugin & { rows(): [string, string][] }} */
export function mcp(options = {}) {
  /** @type {Limits} */
  const limits = { startupMs: options.startupMs ?? 10_000, callMs: options.callMs ?? 60_000 };
  /** @type {Server[]} */
  const servers = [];
  /** @type {string[]} */
  const problems = [];
  /** @type {Plugin & { rows(): [string, string][] }} */
  const plugin = {
    name: "mcp",
    /** @param {Context} ctx */
    async apply(ctx) {
      // The first definition of a name wins: index.js, then the user file, then the workspace file, which is not trusted yet.
      /** @type {[Record<string, ServerConfig>, boolean][]} */
      const sources = [[options.servers ?? {}, true]];
      const user = userConfigPath();
      if (user !== undefined) sources.push([await readServers(user, problems), true]);
      sources.push([await readServers(WORKSPACE_FILE, problems), false]);
      for (const [configs, trusted] of sources) for (const [name, config] of Object.entries(configs)) {
        if (servers.some((server) => server.name === name)) continue;
        if (!config || typeof config !== "object") { problems.push(name + ": the server entry must be an object"); continue; }
        servers.push(new Server(name, config, limits, trusted, ctx));
      }
      for (const server of servers) if (server.state === "pending") server.start();

      // A workspace server asks once, at the first run. A yes starts it; its tools join the next run.
      let asked = false;
      ctx.hook("tools.select", async () => {
        if (asked) return;
        asked = true;
        for (const server of servers) {
          if (server.state !== "untrusted") continue;
          const ok = await ctx.interaction.confirm("Start the MCP server " + server.name + "?", WORKSPACE_FILE + " runs: " + server.commandLine());
          if (ok) server.start(); else server.fail("disabled", "not trusted");
        }
      });

      ctx.inject(["tui"], (ctx) => {
        ctx.tui.command(null, {
          "mcp:show": () => showInfo(ctx, "mcp", plugin.rows()),
        }, { "mcp:show": { title: "MCP", description: "show the MCP servers and their tools", slash: "mcp" } });
      });
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
