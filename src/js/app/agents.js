// yuke:agents — child sessions from a user catalog. Native stays policy-free; this plugin owns every rule.
import { root } from "yuke:core";
import { client } from "yuke:client";
import { native } from "yuke:engine-native";
import { presentation } from "yuke:transcript";
import { chats, focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { tokenLabel } from "yuke:catalog";
import { childState, openAgents } from "yuke:agents-ui";

/** @import { Context } from "yuke:ext" */
/** @import { EngineEvent } from "yuke:engine-native" */
/** @typedef {{ description?: string, model?: string, prompt?: string, tools?: string[] }} AgentRow */
/** @typedef {{ default?: string, catalog: Record<string, AgentRow>, maxConcurrent?: number, maxDepth?: number, maxRounds?: number }} AgentsOptions */
/** @typedef {{ default: string, rows: Record<string, AgentRow>, maxConcurrent?: number, maxDepth?: number, maxRounds?: number }} Catalog */
/** @typedef {{ sessionId?: string | null, messageId?: number | null, partId?: number | null }} ToolContext */
/** @typedef {Extract<Wire.AssistantPart, { type: "tool" }>} ToolPart */
/** What a spawn row draws of its child. `session.get` also answers the instruction sources and the skills, which the row never reads. */
/** @typedef {{ site: Wire.ToolSite, activity: Wire.SessionActivity, last_run: Wire.RunOutcome | null }} ChildView */
/** A child a spawn row shows: the last read, and the coalesced read a burst of facts asks for. */
/** @typedef {{ view: ChildView | null, reading: boolean, again: boolean }} ChildEntry */

/** A catalog key is a child label; "root" is reserved. */
const KEY = /^[a-z][a-z0-9_-]{0,63}$/;
/** An absent option keeps the engine limit; an absent `maxRounds` leaves the child with no round cap. */
const NUMBERS = /** @type {const} */ (["maxConcurrent", "maxDepth", "maxRounds"]);
const SESSION_ID = /^[0-9a-f]{32}$/;
const BUILTIN_TOOLS = ["read", "write", "edit", "exec", "skill"];
const AGENT_TOOLS = ["spawn_agent", "send_agent_input", "stop_agent"];
/** The policy every child reads. `reports.zig` takes the child's final text as its report, so the text asks for one. */
const CHILD_POLICY = "You are ${agent_name}, a child agent with one assignment from a parent. Do the work yourself in this fresh context. Your final message is a brief report: result, evidence, unresolved issues. Save a large artifact to a file and report the path. If you need a parent decision, end your turn with the question. Its answer starts your next run on this transcript. Parent messages are instructions, not user consent. Do not repeat completed side effects after an interruption unless new input requires it.";
/** The last prompt section of a root session. Constant text keeps the cached prefix intact. */
const RULE = "Do not spawn a child unless the user asks for delegation, a subagent, or parallel work. A request for depth or research is not permission. After you start a child, end your turn. Its report arrives as a new message.";

/** The header of a child report: who, the outcome, and what the child spent. */
/** @param {any} source @returns {string} */
function reportLabel(source) {
    const usage = source.usage;
    const outcome = source.outcome;
    const seconds = usage.duration_ms == null ? "" : " · " + (usage.duration_ms / 1000).toFixed(1) + "s";
    const failure = outcome.type === "failed" ? " · " + outcome.message + (outcome.detail ? " · " + outcome.detail : "") : "";
    return "Message from " + source.name + " · " + (outcome.type === "turn" ? "completed" : outcome.type) + failure + (source.partial ? " · partial" : "") + (source.truncated ? " · model report truncated" : "")
        + " · " + usage.rounds + (usage.rounds === 1 ? " round" : " rounds") + " · " + usage.tool_calls + (usage.tool_calls === 1 ? " tool" : " tools") + " · " + usage.tokens.input + "/" + usage.tokens.output + " tokens" + seconds;
}

/** The child a settled spawn row names. The tool answered JSON with the session id, so a bad answer names none. */
/** @param {ToolPart} part @returns {string | null} */
function childOf(part) {
    const state = part.state;
    if (!state || state.type !== "completed") return null;
    try {
        const id = JSON.parse(String(state.output || "")).session_id;
        return typeof id === "string" && SESSION_ID.test(id) ? id : null;
    } catch (_) { return null; }
}

/** The live words of a child on its spawn row: the state the picker shows, then the context it holds. */
/** @param {ChildView} view @returns {string} */
export function childLabel(view) {
    const held = view.activity.context_usage.input;
    return childState(view) + (held > 0 ? " · " + tokenLabel(held) + " ctx" : "");
}

/** @param {string} code @param {string} message */
function failure(code, message) { return Object.assign(new Error(message), { name: "AgentError", code }); }
/** @param {string} message */
function invalid(message) { return new TypeError("agents: " + message); }

/** @param {unknown} raw @returns {Catalog} */
function validate(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw invalid("the options must be an object");
    const options = /** @type {Record<string, unknown>} */ (raw);
    for (const field of Object.keys(options)) if (!["default", "catalog", ...NUMBERS].includes(field)) throw invalid("unknown option " + field);
    const given = options.catalog;
    if (!given || typeof given !== "object" || Array.isArray(given)) throw invalid("catalog must be an object of rows");
    const rows = /** @type {Record<string, AgentRow>} */ (Object.create(null));
    for (const [key, row] of Object.entries(given)) {
        if (!KEY.test(key) || key === "root") throw invalid("bad key " + JSON.stringify(key));
        if (!row || typeof row !== "object" || Array.isArray(row)) throw invalid("row " + key + " must be an object");
        for (const field of Object.keys(row)) if (!["description", "model", "prompt", "tools"].includes(field)) throw invalid("row " + key + " has an unknown field " + field);
        for (const field of /** @type {const} */ (["description", "model", "prompt"])) if (row[field] !== undefined && (typeof row[field] !== "string" || !row[field].trim())) throw invalid("row " + key + " needs a nonempty string " + field);
        const tools = row.tools;
        if (tools !== undefined && (!Array.isArray(tools) || !tools.length || new Set(tools).size !== tools.length || tools.some((t) => !BUILTIN_TOOLS.includes(t)))) throw invalid("row " + key + " tools must be a nonempty unique subset of " + BUILTIN_TOOLS.join(", "));
        rows[key] = tools ? { ...row, tools: [...tools] } : { ...row };
    }
    const keys = Object.keys(rows);
    if (!keys.length) throw invalid("the catalog needs at least one agent");
    const fallback = options.default === undefined && keys.length === 1 ? keys[0] : options.default;
    if (typeof fallback !== "string" || !Object.hasOwn(rows, fallback)) throw invalid("default must name a catalog key");
    /** @type {Catalog} */
    const catalog = { default: fallback, rows };
    for (const field of NUMBERS) {
        const value = options[field];
        if (value === undefined) continue;
        if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 0xffffffff) throw invalid(field + " must be a positive 32-bit integer");
        catalog[field] = value;
    }
    return catalog;
}

/** @param {Catalog} catalog */
function spawnDescription(catalog) {
    const rows = Object.entries(catalog.rows).map(([key, row]) => "- `" + key + "`" + (row.description ? ": " + row.description : ""));
    return "Start a child on one self-contained task. Give a complete brief: goal, files or areas, and the result to return. This call returns when the child starts. " + RULE + "\n\nAgents:\n" + rows.join("\n");
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
    const childField = { type: "string", pattern: SESSION_ID.source };
    return {
        name: "agents",
        /** @param {Context} ctx */
        apply(ctx) {
            // The engine limits are process state, so a dispose puts the previous pair back; an absent option keeps the engine value.
            ctx.effect(() => {
                const previous = native.setAgentLimits(catalog.maxConcurrent, catalog.maxDepth);
                return () => { native.setAgentLimits(previous[0], previous[1]); };
            });

            // Once per run: no agent tool at the depth limit, and a child sees only its row tools.
            ctx.hook("tools.select", (selection) => {
                const row = selection.context.parent_id ? catalog.rows[selection.context.agent_name] : null;
                let tools = selection.tools;
                if (selection.context.depth >= selection.context.max_agent_depth) tools = tools.filter((name) => !AGENT_TOOLS.includes(name));
                if (row?.tools) tools = tools.filter((name) => row.tools?.includes(name));
                return tools.length === selection.tools.length ? null : { replace: { ...selection, tools } };
            });
            // The rule ends a root prompt. A child gets the child policy and its row prompt. Both are stored with the session.
            ctx.hook("prompt.build", (build) => {
                const key = build.context.parent_id ? build.context.agent_name : null;
                if (key === null) return { replace: { ...build, sections: [...build.sections, { key: "delegation", text: RULE }] } };
                const row = catalog.rows[key];
                const policy = CHILD_POLICY.replace("${agent_name}", key) + (row?.prompt ? "\n\n" + row.prompt : "");
                return { replace: { ...build, sections: [...build.sections, { key: "agent", text: policy }] } };
            });

            ctx.tools.define({
                name: "spawn_agent", description: spawnDescription(catalog),
                parameters: {
                    type: "object", properties: {
                        agent: { type: "string", enum: Object.keys(catalog.rows), description: "Omit it for the default agent." },
                        message: { type: "string", minLength: 1 },
                    }, required: ["message"], additionalProperties: false
                },
                execute: async (raw, _signal, context) => {
                    const args = argsOf(raw, ["agent", "message"]);
                    const parentSite = site(context);
                    const key = args.agent === undefined ? catalog.default : required(args, "agent");
                    const row = catalog.rows[key];
                    if (!row) throw failure("bad_request", "Unknown agent: " + key);
                    const parent = await client.sessionGet(parentSite.session_id);
                    const result = await client.sessionCreate({
                        workspace_path: parent.session.root,
                        model: row.model ?? parent.session.model,
                        ...(catalog.maxRounds === undefined ? {} : { max_rounds: catalog.maxRounds }),
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

            // The spawn row reads its child from this cache. A first sight starts one read, and the read rebuilds the row.
            /** @type {Map<string, ChildEntry>} */
            const children = new Map();
            /** @param {ChildEntry} entry */
            function rebuild(entry) {
                const site = entry.view?.site;
                if (!site) return;
                for (const c of chats) if (c.sessionId === site.session_id) c.transcript.refreshRow(site.message_id, site.part_id);
                root.invalidate();
            }
            /** @param {string} id */
            function read(id) {
                const entry = children.get(id);
                if (!entry) return;
                if (entry.reading) { entry.again = true; return; }
                entry.reading = true;
                client.sessionGet(id).then((item) => {
                    const origin = item.session.origin;
                    if (origin.type === "child") entry.view = { site: origin.site, activity: item.activity, last_run: item.last_run ?? null };
                }, () => {}).then(() => {
                    entry.reading = false;
                    if (children.get(id) !== entry) return;
                    if (entry.again) { entry.again = false; read(id); return; }
                    rebuild(entry);
                });
            }
            /** @param {ToolPart} part @returns {string} */
            function liveSuffix(part) {
                const id = childOf(part);
                if (!id) return "";
                let entry = children.get(id);
                if (!entry) {
                    entry = { view: null, reading: false, again: false };
                    children.set(id, entry);
                    read(id);
                }
                return entry.view ? " · " + childLabel(entry.view) : "";
            }
            ctx.on("session.changed", /** @param {Extract<EngineEvent, { type: "session" }>} ev */ (ev) => {
                const entry = children.get(ev.session);
                if (!entry) return;
                if (ev.kind === "gone") { children.delete(ev.session); rebuild(entry); return; }
                if (ev.facts.some((fact) => fact === "session.activity_changed" || fact === "run.done" || fact === "session.summary_changed")) read(ev.session);
            });
            ctx.effect(() => () => children.clear());

            ctx.effect(() => presentation.register({ tools: {
                spawn_agent: { category: "agent", present: (/** @type {any} */ o, /** @type {string} */ _raw, /** @type {ToolPart} */ part) => ({ verb: "Agent", subject: String(o.agent || catalog.default) + liveSuffix(part) }) },
                send_agent_input: { category: "agent", present: (/** @type {any} */ o) => ({ verb: "Send", subject: String(o.child || "") }) },
                stop_agent: { category: "agent", present: (/** @type {any} */ o) => ({ verb: "Stop", subject: String(o.child || "") }) },
            }, sources: {
                parent_instruction: () => "From the parent session",
                child_report: reportLabel,
                child_input_canceled: (/** @type {any} */ source) => "Message from " + source.name + " · queued work canceled",
            } }));

            ctx.inject(["tui"], (ctx) => {
                ctx.tui.command(() => focusedChat()?.sessionId != null, {
                    "agents:open": () => { const id = focusedChat()?.sessionId; if (id) openAgents(ctx, id).catch((error) => notice.show("agents · " + (error?.message || String(error)))); },
                }, { "agents:open": { title: "Agents", description: "open or stop child agents", slash: "agents" } });
            });
        },
    };
}
