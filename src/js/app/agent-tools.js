// yuke:agent-tools — thin tools over stored child sessions.
import { client } from "yuke:client";
import { NAME, check, failure, spawnAgent } from "yuke:agents";

/** @import { Context } from "yuke:ext" */

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
/** @param {unknown} value @param {number} fallback @param {number} min @param {number} max @returns {number} */
function integer(value, fallback, min, max) {
    if (value === undefined) return fallback;
    if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) throw failure("bad_request", "The page bound is invalid.");
    return value;
}
/** @param {string} parentId @param {string} target @returns {Promise<Wire.SessionListItem>} */
export async function ownedChild(parentId, target) {
    const byId = /^[0-9a-f]{32}$/.test(target);
    if (!byId && !NAME.test(target)) throw failure("bad_request", "Use an owned child ID or name.");
    const child = await (byId ? client.sessionGet(target) : client.sessionGet(parentId, target));
    if (child.session.origin.type !== "child" || child.session.origin.site.session_id !== parentId) throw failure("bad_request", "The child belongs to another parent.");
    return child;
}
/** @param {Wire.SessionListItem} item */
export function agentRow(item) {
    return { name: item.session.name, session_id: item.session.id, model: item.session.model, reasoning: item.session.reasoning, activity: item.activity, last_run: item.last_run ?? null };
}
/** @param {string} parentId */
export async function allChildren(parentId) {
    /** @type {Wire.SessionListItem[]} */
    const items = [];
    let cursor;
    do {
        const page = await client.sessionList({ population: { type: "children", parent_id: parentId }, limit: 100, ...(cursor ? { cursor } : {}) });
        items.push(...page.items);
        cursor = page.next_cursor;
    } while (cursor);
    return items;
}
/** @param {string} parentId */
export async function stopAllChildren(parentId) {
    const children = await allChildren(parentId);
    const results = await Promise.allSettled(children.map((child) => client.sessionCancelRun(child.session.id, true)));
    const failed = results.filter((result) => result.status === "rejected").length;
    const stopped = results.filter((result) => result.status === "fulfilled" && (result.value.canceled_run != null || result.value.cleared_compaction != null || result.value.cleared_inputs?.length)).length;
    return { stopped, unchanged: results.length - stopped - failed, failed };
}

/** @type {Record<string, unknown>} */
const childField = { type: "string", description: "Child session ID or name." };
const definitions = [
    { name: "spawn_agent", description: "Start a child agent on one self-contained task in a fresh context. Delegate read-heavy or independent work: a wide search, a review, a separate implementation. Do a single focused task yourself. One child per task; never two on the same question. Give a complete brief: goal, files or areas, and the result to return. The name is unique per parent; later calls use it. model is required: small for narrow research or simple edits, medium for implementation, analysis, or review. The child reports when its run ends; the report resumes your next turn. Finish independent work, then end your turn to wait.", fields: { name: { type: "string", pattern: NAME.source }, message: { type: "string", minLength: 1 }, model: { type: "string", enum: ["small", "medium"] } }, required: ["name", "message", "model"] },
    { name: "send_agent_input", description: "Send one child a follow-up. The child keeps its transcript, so refer to earlier work. Its next report resumes your turn. The result says whether the run started or is queued; queued input waits and has not failed.", fields: { child: childField, message: { type: "string", minLength: 1 } }, required: ["child", "message"] },
    { name: "stop_agent", description: "Stop a child's current run; drop its queued input. The transcript stays; completed side effects are not undone.", fields: { child: childField }, required: ["child"] },
    { name: "list_agents", description: "List each child's name, session ID, model, activity, and last run outcome. A finished child stays reusable. Pass cursor for the next page.", fields: { cursor: { type: "string" }, limit: { type: "integer", minimum: 1, maximum: 50 } }, required: [] },
];

export const agentToolsPlugin = {
    name: "agent-tools",
    /** @param {Context} ctx */
    apply(ctx) {
        for (const definition of definitions) {
            try {
                ctx.tools.define({
                    name: definition.name, description: definition.description,
                    spawnsAgents: definition.name === "spawn_agent",
                    parameters: { type: "object", properties: definition.fields, required: definition.required, additionalProperties: false },
                    execute: async (raw, signal, context) => {
                        const args = argsOf(raw, Object.keys(definition.fields));
                        const parentId = context.sessionId;
                        if (!parentId) throw failure("bad_request", "The tool has no parent session.");
                        check(signal);
                        if (definition.name === "spawn_agent") {
                            if (context.messageId == null || context.partId == null) throw failure("bad_request", "The tool has no live parent site.");
                            return spawnAgent(ctx, { name: required(args, "name"), message: required(args, "message"), model: args.model }, signal, { sessionId: parentId, messageId: context.messageId, partId: context.partId });
                        }
                        if (definition.name === "list_agents") {
                            const limit = integer(args.limit, 25, 1, 50);
                            const cursor = args.cursor === undefined ? undefined : required(args, "cursor");
                            const page = await client.sessionList({ population: { type: "children", parent_id: parentId }, limit, ...(cursor ? { cursor } : {}) });
                            return { items: page.items.map(agentRow), next_cursor: page.next_cursor ?? null, total: page.total };
                        }
                        const child = await ownedChild(parentId, required(args, "child"));
                        check(signal);
                        if (definition.name === "send_agent_input") {
                            if (context.messageId == null || context.partId == null) throw failure("bad_request", "The tool has no live parent site.");
                            const result = await client.sessionSendInput(child.session.id, required(args, "message"), { session_id: parentId, message_id: context.messageId, part_id: context.partId });
                            return { state: result.type };
                        }
                        return client.sessionCancelRun(child.session.id, true);
                    },
                });
            } catch (error) {
                if (/** @type {Error} */ (error).message !== "another tool already has this name") throw error;
            }
        }
    },
};
