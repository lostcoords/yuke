// yuke:agents — child sessions from a user catalog. Native stays policy-free; this plugin owns every rule.
import { client } from "yuke:client";
import { native } from "yuke:engine-native";
import { presenters } from "yuke:transcript";
import { focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { openAgents } from "yuke:agents-ui";

/** @import { Context } from "yuke:ext" */
/** @typedef {{ description?: string, model?: string, prompt?: string, tools?: string[] }} AgentRow */
/** @typedef {{ default?: string, agents: Record<string, AgentRow>, maxConcurrent?: number, maxDepth?: number, maxRounds?: number }} AgentsOptions */
/** @typedef {{ default: string, agents: Record<string, AgentRow>, maxConcurrent: number, maxDepth: number, maxRounds: number }} Catalog */
/** @typedef {{ sessionId?: string | null, messageId?: number | null, partId?: number | null }} ToolContext */

/** A catalog key is a child label; "root" is reserved. */
const KEY = /^[a-z][a-z0-9_-]{0,63}$/;
const SESSION_ID = /^[0-9a-f]{32}$/;
const BUILTIN_TOOLS = ["read", "write", "edit", "exec", "skill"];
const LIMITS = { maxConcurrent: 8, maxDepth: 1, maxRounds: 50 };
/** The last system prompt section of a root session. Constant text keeps the cached prefix intact. */
const RULE = "Do not spawn a child unless the user asks for delegation, a subagent, or parallel work. A request for depth or research is not permission. After you start a child, end your turn. Its report arrives as a new message.";

/** @param {string} code @param {string} message */
function failure(code, message) { return Object.assign(new Error(message), { name: "AgentError", code }); }
/** @param {string} message */
function invalid(message) { return new TypeError("agents: " + message); }

/** @param {unknown} raw @returns {Catalog} */
function validate(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw invalid("the options must be an object");
    const options = /** @type {Record<string, unknown>} */ (raw);
    for (const field of Object.keys(options)) if (!["default", "agents", ...Object.keys(LIMITS)].includes(field)) throw invalid("unknown option " + field);
    const rows = options.agents;
    if (!rows || typeof rows !== "object" || Array.isArray(rows)) throw invalid("agents must be an object of catalog rows");
    const agents = /** @type {Record<string, AgentRow>} */ (Object.create(null));
    for (const [key, row] of Object.entries(rows)) {
        if (!KEY.test(key) || key === "root") throw invalid("bad key " + JSON.stringify(key));
        if (!row || typeof row !== "object" || Array.isArray(row)) throw invalid("row " + key + " must be an object");
        for (const field of Object.keys(row)) if (!["description", "model", "prompt", "tools"].includes(field)) throw invalid("row " + key + " has an unknown field " + field);
        for (const field of /** @type {const} */ (["description", "model", "prompt"])) if (row[field] !== undefined && (typeof row[field] !== "string" || !row[field].trim())) throw invalid("row " + key + " needs a nonempty string " + field);
        const tools = row.tools;
        if (tools !== undefined && (!Array.isArray(tools) || !tools.length || new Set(tools).size !== tools.length || tools.some((t) => !BUILTIN_TOOLS.includes(t)))) throw invalid("row " + key + " tools must be a nonempty unique subset of " + BUILTIN_TOOLS.join(", "));
        agents[key] = { ...row };
    }
    const keys = Object.keys(agents);
    if (!keys.length) throw invalid("the catalog needs at least one agent");
    const fallback = options.default === undefined && keys.length === 1 ? keys[0] : options.default;
    if (typeof fallback !== "string" || !Object.hasOwn(agents, fallback)) throw invalid("default must name a catalog key");
    /** @type {Catalog} */
    const catalog = { default: fallback, agents, ...LIMITS };
    for (const field of /** @type {const} */ (["maxConcurrent", "maxDepth", "maxRounds"])) {
        const value = options[field];
        if (value === undefined) continue;
        if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 0xffffffff) throw invalid(field + " must be a positive 32-bit integer");
        catalog[field] = value;
    }
    return catalog;
}

/** @param {Catalog} catalog */
function spawnDescription(catalog) {
    const rows = Object.entries(catalog.agents).map(([key, row]) => "- `" + key + "`" + (row.description ? ": " + row.description : ""));
    return "Start a child on one self-contained task. Give a complete brief: goal, files or areas, and the result to return. This call returns when the child starts. The report comes later as a new message. " + RULE + "\n\nAgents:\n" + rows.join("\n");
}

/** @param {unknown} value @param {string[]} fields @returns {Record<string, any>} */
function argsOf(value, fields) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw failure("bad_request", "The arguments must be an object.");
    for (const field of Object.keys(value)) if (!fields.includes(field)) throw failure("bad_request", "Unknown argument: " + field);
    return value;
}
/** @param {Record<string, any>} args @param {string} key @returns {string} */
function required(args, key) {
    if (typeof args[key] !== "string" || !args[key].trim()) throw failure("bad_request", key + " must be a nonempty string.");
    return args[key];
}
/** @param {ToolContext} context */
function site(context) {
    if (!context.sessionId) throw failure("bad_request", "The tool has no parent session.");
    if (context.messageId == null || context.partId == null) throw failure("bad_request", "The tool has no live parent site.");
    return { session_id: context.sessionId, message_id: context.messageId, part_id: context.partId };
}
/** @param {string} parentId @param {string} target @returns {Promise<Wire.SessionListItem>} */
async function ownedChild(parentId, target) {
    if (!SESSION_ID.test(target)) throw failure("bad_request", "child must be a child session ID.");
    const child = await client.sessionGet(target);
    if (child.session.origin.type !== "child" || child.session.origin.site.session_id !== parentId) throw failure("bad_request", "The child belongs to another parent.");
    return child;
}

/** @param {AgentsOptions} options */
export function agents(options) {
    const catalog = validate(options);
    const childField = { type: "string", pattern: SESSION_ID.source, description: "Child session ID." };
    return {
        name: "agents",
        /** @param {Context} ctx */
        apply(ctx) {
            // The engine limits are process state, so a dispose puts the previous pair back.
            ctx.effect(() => {
                const previous = native.setAgentLimits(catalog.maxConcurrent, catalog.maxDepth);
                return () => { native.setAgentLimits(previous[0], previous[1]); };
            });

            // The rule ends a root prompt. A child gets its row prompt and only its row tools.
            ctx.hook("request.build", (request) => {
                const key = request.context.parent_id ? request.context.agent_name : null;
                if (key === null) return { replace: { ...request, system: request.system + "\n\n" + RULE } };
                const row = catalog.agents[key];
                if (!row) return null;
                const system = row.prompt ? request.system + "\n\n" + row.prompt : request.system;
                const tools = row.tools ? request.tools.filter((/** @type {{ name: string }} */ tool) => row.tools?.includes(tool.name)) : request.tools;
                return { replace: { ...request, system, tools } };
            });
            // A child that names a tool outside its row is stopped before the process runs it.
            ctx.hook("tool.before", (call) => {
                const row = call.context.parent_id ? catalog.agents[call.context.agent_name] : null;
                if (!row?.tools || row.tools.includes(call.name)) return null;
                return { block: "The tool " + call.name + " is not available to this agent." };
            });

            ctx.tools.define({
                name: "spawn_agent", description: spawnDescription(catalog), spawnsAgents: true,
                parameters: {
                    type: "object", properties: {
                        agent: { type: "string", enum: Object.keys(catalog.agents), description: "A catalog key from the list. Omit it for the default agent." },
                        message: { type: "string", minLength: 1, description: "The full task for the child." },
                    }, required: ["message"], additionalProperties: false
                },
                execute: async (raw, _signal, context) => {
                    const args = argsOf(raw, ["agent", "message"]);
                    const parentSite = site(context);
                    const key = args.agent === undefined ? catalog.default : required(args, "agent");
                    const row = catalog.agents[key];
                    if (!row) throw failure("bad_request", "Unknown agent: " + key);
                    const parent = await client.sessionGet(parentSite.session_id);
                    const result = await client.sessionCreate({
                        workspace_path: parent.session.root,
                        model: row.model ?? parent.session.model,
                        max_rounds: catalog.maxRounds,
                        initial_input: { type: "content", content: client.textContent(required(args, "message")) },
                        child: { name: key, site: parentSite },
                    });
                    if (!result.input) throw failure("runtime_failed", "The child session has no initial run.");
                    return { session_id: result.session.id, agent: key, model: result.session.model, state: result.input.type };
                },
            });
            ctx.tools.define({
                name: "send_agent_input", description: "Send one child a follow-up. The child keeps its transcript, so refer to earlier work. Its next report comes as a new message, so end your turn and wait.",
                parameters: { type: "object", properties: { child: childField, message: { type: "string", minLength: 1 } }, required: ["child", "message"], additionalProperties: false },
                execute: async (raw, _signal, context) => {
                    const args = argsOf(raw, ["child", "message"]);
                    const parentSite = site(context);
                    const child = await ownedChild(parentSite.session_id, required(args, "child"));
                    const result = await client.sessionSendInput(child.session.id, client.textContent(required(args, "message")), parentSite);
                    return { state: result.type };
                },
            });
            ctx.tools.define({
                name: "stop_agent", description: "Stop a child's current run; drop its queued input. The transcript stays; completed side effects are not undone.",
                parameters: { type: "object", properties: { child: childField }, required: ["child"], additionalProperties: false },
                execute: async (raw, _signal, context) => {
                    const args = argsOf(raw, ["child"]);
                    const child = await ownedChild(site(context).session_id, required(args, "child"));
                    return client.sessionCancelRun(child.session.id, true);
                },
            });

            ctx.effect(() => {
                const own = {
                    spawn_agent: { category: "agent", present: (/** @type {any} */ o) => ({ verb: "Agent", subject: String(o.agent || "") + " · " + String(o.model || "") }) },
                    send_agent_input: { category: "agent", present: (/** @type {any} */ o) => ({ verb: "Send", subject: String(o.child || "") }) },
                    stop_agent: { category: "agent", present: (/** @type {any} */ o) => ({ verb: "Stop", subject: String(o.child || "") }) },
                };
                const previous = Object.fromEntries(Object.keys(own).map((name) => [name, presenters[name]]));
                Object.assign(presenters, own);
                return () => { for (const name of Object.keys(own)) { if (previous[name] === undefined) delete presenters[name]; else presenters[name] = previous[name]; } };
            });

            ctx.inject(["tui"], (ctx) => {
                ctx.tui.command(() => focusedChat()?.sessionId != null, {
                    "agents:open": () => { const id = focusedChat()?.sessionId; if (id) openAgents(ctx, id).catch((error) => notice.show("agents · " + (error?.message || String(error)))); },
                }, { "agents:open": { title: "Agents", description: "open or stop child agents", slash: "agents" } });
            });
        },
    };
}
