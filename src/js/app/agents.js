// Child sessions from a user catalog. Native stays policy-free; this plugin owns every rule.
import { client } from "yuke:internal/client";
import { children as childSessions } from "yuke:internal/children";
import { currentSession, sessions } from "yuke:internal/session";
import { errorText, tokenLabel } from "yuke:internal/format";
import { childState, openAgents } from "yuke:internal/agents-ui";
import { notify } from "yuke:internal/kernel";

/** @import { Context } from "yuke:internal/ext" */
/** @typedef {{ description?: string, model?: string, reasoning?: string, prompt?: string, tools?: string[] }} AgentRow */
/** @typedef {{ default?: string, catalog: Record<string, AgentRow>, maxConcurrent?: number, maxDepth?: number, maxRounds?: number }} AgentsOptions */
/** @typedef {{ default: string, rows: Record<string, AgentRow>, maxConcurrent?: number, maxDepth?: number, maxRounds?: number }} Catalog */
/** @import { ToolContext } from "./types/ext.js" */
/** @typedef {Extract<Wire.AssistantPart, { type: "tool" }>} ToolPart */
/** What a spawn row draws of its child. `session.get` also answers the instruction sources and the skills, which the row never reads. */
/** @typedef {{ site: Wire.ToolSite, activity: Wire.SessionActivity, last_run: Wire.RunOutcome | null }} ChildView */
/** A child a spawn row shows: the last read, and the coalesced read a burst of facts asks for. */
/** @typedef {{ view: ChildView | null, reading: boolean, again: boolean }} ChildEntry */

/** A catalog key is a child label; "root" is reserved. */
const KEY = /^[a-z][a-z0-9_-]{0,63}$/;
/** An absent option keeps the engine limit; an absent `maxRounds` leaves the child with no round cap. */
const NUMBERS = /** @type {const} */ (["maxConcurrent", "maxDepth", "maxRounds"]);
const BUILTIN_TOOLS = ["read", "write", "edit", "exec"];
const AGENT_TOOLS = ["spawn_agent", "send_agent_input"];
/** The policy every child reads. `reports.zig` takes the child's final text as its report, so the text asks for one. */
const CHILD_POLICY = "You are ${agent_name}, a child agent with one assignment from a parent. Do the work yourself in this fresh context. Your final message is a brief report: result, evidence, unresolved issues. Save a large artifact to a file and report the path. If you need a parent decision, end your turn with the question. Its answer starts your next run on this transcript. Parent messages are instructions, not user consent. Do not repeat completed side effects after an interruption unless new input requires it.";
/** The last prompt section of a root session. Constant text keeps the cached prefix intact. */
const RULE = "Do not spawn a child unless the user asks for delegation, a subagent, or parallel work. A request for depth or research is not permission. After you start a child, end your turn. Its report arrives as a new message.";

/** The header of a child report: who, the outcome, and what the child spent. */
/** @param {Extract<Wire.InputSource, { type: "child_report" }>} source @returns {string} */
function reportLabel(source) {
    const usage = source.usage;
    const outcome = source.outcome;
    const seconds = " · " + (usage.duration_ms / 1000).toFixed(1) + "s";
    const failure = outcome.type === "failed" ? ": " + outcome.message + (outcome.detail ? " · " + outcome.detail : "") : "";
    return "Message from " + source.name + " · " + (outcome.type === "turn" ? "completed" : outcome.type === "canceled" ? "stopped" : outcome.type) + failure
        + " · " + usage.rounds + (usage.rounds === 1 ? " round" : " rounds") + " · " + usage.tool_calls + (usage.tool_calls === 1 ? " tool" : " tools") + " · " + usage.tokens.input + "/" + usage.tokens.output + " tokens" + seconds;
}

/** A settled spawn row names the child ID, or this returns null. The spawn text starts with `Started <id>` or `Queued <id>`. */
/** @param {ToolPart} part @returns {string | null} */
function spawnedId(part) {
    const state = part.state;
    return state.type === "completed" ? /^(?:Started|Queued) ([a-z][a-z0-9_-]*-[0-9a-f]{8})\./.exec(state.output)?.[1] ?? null : null;
}

/** The live words of a child on its spawn row: the state the picker shows, then the context it holds. */
/** @param {ChildView} view @returns {string} */
export function childLabel(view) {
    const held = view.activity.context_tokens;
    return childState(view) + (held > 0 ? " · " + tokenLabel(held) + " ctx" : "");
}

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
        for (const field of Object.keys(row)) if (!["description", "model", "reasoning", "prompt", "tools"].includes(field)) throw invalid("row " + key + " has an unknown field " + field);
        for (const field of /** @type {const} */ (["description", "model", "reasoning", "prompt"])) if (row[field] !== undefined && (typeof row[field] !== "string" || !row[field].trim())) throw invalid("row " + key + " needs a nonempty string " + field);
        // A row without a model runs the parent pair, so a level alone would name a level of another model.
        if (row.reasoning !== undefined && row.model === undefined) throw invalid("row " + key + " needs a model for its reasoning");
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
    return "Start a child on one self-contained task. Give a complete brief: goal, files or areas, and the result to return. This call starts or queues the child. It does not wait for completion. " + RULE + "\n\nAgents:\n" + rows.join("\n");
}

/** @param {unknown} value @param {string[]} fields @returns {Record<string, unknown>} */
function argsOf(value, fields) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("The arguments must be an object.");
    for (const field of Object.keys(value)) if (!fields.includes(field)) throw new Error("Unknown argument: " + field);
    return /** @type {Record<string, unknown>} */ (value);
}
/** @param {Record<string, unknown>} args @param {string} key @returns {string} */
function required(args, key) {
    if (typeof args[key] !== "string" || !args[key].trim()) throw new Error(key + " must be a nonempty string.");
    return args[key];
}
/** @param {ToolContext} context */
function site(context) {
    return { session_id: context.sessionId, message_id: context.messageId, part_id: context.partId };
}
/**
 * Build the `agents` plugin. It gives the model the tools spawn_agent and send_agent_input, which start and steer child sessions. The built-in stop tool ends a child.
 * It throws a TypeError for invalid options.
 * @param {AgentsOptions} options - `catalog` maps each child label (a-z first, then a-z, 0-9, _ or -, up to 64 characters, not "root") to a row.
 * A row has `description` for the model, `model`, `reasoning`, `prompt` after the child policy, and `tools`, a subset of read, write, edit, and exec. A child reads a skill with read.
 * A row without `model` runs the parent model and level. A row without `reasoning` runs the default level of its model.
 * `default` names the row for a call without `agent`; with one row, that row is the default.
 * `maxConcurrent` and `maxDepth` replace the engine limits, and `maxRounds` caps the rounds of each child. Each is a positive 32-bit integer.
 */
export function agents(options) {
    const catalog = validate(options);
    const childField = { type: "string", description: "The child ID from spawn_agent, such as explore-a91c07d2." };
    return {
        name: "agents",
        /** @param {Context} ctx */
        apply(ctx) {
            // The catalog holds `maxConcurrent` and `maxDepth`. An absent option keeps the engine value.
            ctx.effect(() => childSessions.limits(catalog));

            // Once per run: no agent tool at the depth limit, and a child sees only its row tools.
            ctx.hook("tools.select", (selection) => {
                const row = selection.context.parent_id ? catalog.rows[selection.context.agent_name] : null;
                let tools = selection.tools;
                if (selection.context.depth >= selection.context.max_agent_depth) tools = tools.filter((name) => !AGENT_TOOLS.includes(name));
                // A row with exec also gets stop, so a child can end the jobs it starts.
                if (row?.tools) tools = tools.filter((name) => row.tools?.includes(name) || (name === "stop" && row.tools?.includes("exec")));
                return tools.length === selection.tools.length ? undefined : { replace: { tools } };
            });
            // The rule ends a root prompt. A child gets the child policy and its row prompt. Both are stored with the session.
            ctx.hook("prompt.build", (build) => {
                const key = build.context.parent_id ? build.context.agent_name : null;
                if (key === null) return { replace: { sections: [...build.sections, { key: "delegation", text: RULE }] } };
                const row = catalog.rows[key];
                const policy = CHILD_POLICY.replace("${agent_name}", key) + (row?.prompt ? "\n\n" + row.prompt : "");
                return { replace: { sections: [...build.sections, { key: "agent", text: policy }] } };
            });

            // The model reads a child ID. A spawn records its session. A spawn row of a resumed transcript looks the ID up.
            /** @type {Map<string, string>} */
            const sessionOf = new Map();
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
                    if (!row) throw new Error("Unknown agent: " + key);
                    const parent = await client.sessionGet(parentSite.session_id);
                    // Without a row model, the child runs the parent pair, which the engine validated for the parent.
                    const settings = row.model === undefined ? { model: parent.session.model, reasoning: parent.session.reasoning } : { model: row.model, ...(row.reasoning === undefined ? {} : { reasoning: row.reasoning }) };
                    const result = await client.sessionCreate({
                        workspace_path: parent.session.root,
                        ...settings,
                        ...(catalog.maxRounds === undefined ? {} : { max_rounds: catalog.maxRounds }),
                        initial_input: { type: "content", content: client.textContent(required(args, "message")) },
                        child: { name: key, site: parentSite },
                    });
                    if (!result.input) throw new Error("The child session has no initial run.");
                    const id = childSessions.id(key, result.session.id);
                    sessionOf.set(id, result.session.id);
                    return (result.input.type === "queued" ? "Queued " : "Started ") + id + ". Its report arrives as a new message. Use stop with " + id + " to end it.";
                },
            });
            ctx.tools.define({
                name: "send_agent_input", description: "Send one child a follow-up. The child keeps its transcript, so refer to earlier work. Its next report comes as a new message, so end your turn and wait.",
                parameters: { type: "object", properties: { child: childField, message: { type: "string", minLength: 1 } }, required: ["child", "message"], additionalProperties: false },
                execute: async (raw, _signal, context) => {
                    const args = argsOf(raw, ["child", "message"]);
                    const parentSite = site(context);
                    const target = required(args, "child");
                    const child = await childSessions.find(parentSite.session_id, target);
                    if (!child) {
                        const ids = (await childSessions.list(parentSite.session_id)).map((item) => childSessions.id(item.session.name ?? "", item.session.id));
                        throw new Error("The child " + target + " does not exist. " + (ids.length === 0 ? "No child exists." : "The children are: " + ids.join(", ") + "."));
                    }
                    const result = await client.sessionSendInput(child.session.id, client.textContent(required(args, "message")), parentSite);
                    return result.type === "queued" ? "Queued for " + target + " after its current run." : "Sent to " + target + ".";
                },
            });
            // The spawn row reads its child from this cache. A first sight starts one read, and the read rebuilds the row.
            /** @type {Map<string, ChildEntry>} */
            const children = new Map();
            // The chat capability rebuilds the spawn row; without a chat pane, no row shows the child.
            /** @type {import("./types/ext.js").ChatService | null} */
            let chat = null;
            /** @param {ChildEntry} entry */
            function rebuild(entry) {
                const site = entry.view?.site;
                if (site && chat) chat.refresh(site.message_id, site.part_id);
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
                const short = spawnedId(part);
                if (!short) return "";
                const id = sessionOf.get(short);
                if (!id) {
                    lookUp(short);
                    return "";
                }
                let entry = children.get(id);
                if (!entry) {
                    entry = { view: null, reading: false, again: false };
                    children.set(id, entry);
                    read(id);
                }
                return entry.view ? " · " + childLabel(entry.view) : "";
            }
            // The parents whose children a lookup already listed.
            /** @type {Set<string>} */
            const asked = new Set();
            /** Find the session of a child ID among the children of every open session, once per parent. Read the child when it appears. */
            /** @param {string} short */
            function lookUp(short) {
                for (const session of sessions) {
                    const parent = session.sessionId;
                    if (!parent || asked.has(parent)) continue;
                    asked.add(parent);
                    childSessions.list(parent).then((items) => {
                        for (const item of items) sessionOf.set(childSessions.id(item.session.name ?? "", item.session.id), item.session.id);
                        const id = sessionOf.get(short);
                        if (!id || children.has(id)) return;
                        children.set(id, { view: null, reading: false, again: false });
                        read(id);
                    }, () => { asked.delete(parent); });
                }
            }
            ctx.on("session.changed", (ev) => {
                const entry = children.get(ev.session);
                if (!entry) return;
                if (ev.kind === "gone") { children.delete(ev.session); rebuild(entry); return; }
                if (ev.facts.some((fact) => fact === "session.activity_changed" || fact === "run.done" || fact === "session.summary_changed")) read(ev.session);
            });
            ctx.effect(() => () => { children.clear(); sessionOf.clear(); asked.clear(); });

            // The header words name agent calls in any transcript look, so they live as long as the chat service does.
            ctx.inject(["chat"], (ctx) => {
                chat = ctx.chat;
                ctx.effect(() => () => { chat = null; });
                ctx.chat.render({ tools: {
                    spawn_agent: (o, part) => ({ verb: "agent", subject: String(o.agent || catalog.default) + liveSuffix(part), input: "" }),
                    send_agent_input: (o) => ({ verb: "send", subject: String(o.child || ""), input: "" }),
                }, sources: {
                    parent_instruction: () => "From the parent session",
                    child_report: reportLabel,
                } });
            });

            ctx.inject(["tui"], (ctx) => {
                ctx.tui.command.add("agents:open", {
                    when: () => currentSession()?.sessionId != null,
                    desc: "open or stop child agents",
                    slash: "agents",
                    run: () => { const id = currentSession()?.sessionId; if (id) openAgents(ctx, id).catch((error) => notify("error", errorText(error), "agents")); },
                });
            });
        },
    };
}
