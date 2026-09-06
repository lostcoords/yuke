// yuke:agent-tools — thin tools over stored child sessions.
import { client } from "yuke:client";
import { NAME, check, failure, spawnAgent } from "yuke:agents";

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
const childField = { type: "string", description: "The child's session ID or its name." };
const pageFields = { before_message_id: { type: "integer", minimum: 0, description: "0 reads the newest page. Pass the next_before_message_id of a result to read the page before it." }, limit: { type: "integer", minimum: 1, maximum: 50 } };
const definitions = [
    { name: "spawn_agent", description: "Start a child agent on one independent task. The name is unique per parent; later calls address the child by it. Nesting follows the configured maximum agent depth. The model is required: small for narrow research or simple edits, medium for general implementation, analysis, and review. Returns the child's name and session ID and whether its run started or is queued. The child reports back when its run ends; queued descendants are handled automatically.", fields: { name: { type: "string", pattern: NAME.source }, message: { type: "string", minLength: 1 }, model: { type: "string", enum: ["small", "medium"] } }, required: ["name", "message", "model"] },
    { name: "send_agent_input", description: "Send a new message to one of your children. Returns whether the run started or is queued. A queued message waits; it has not failed.", fields: { child: childField, message: { type: "string", minLength: 1 } }, required: ["child", "message"] },
    { name: "stop_agent", description: "Stop a child's current run and drop its queued messages. The transcript stays; completed side effects are not undone.", fields: { child: childField }, required: ["child"] },
    { name: "list_agents", description: "List your children with their name, state, model, and last run outcome. A finished child stays reusable. Pass cursor to read the next page.", fields: { cursor: { type: "string" }, limit: { type: "integer", minimum: 1, maximum: 50 } }, required: [] },
    { name: "read_agent", description: "Read a page of a child's full transcript, oldest first within each page. Pass before_message_id from a result's next_before_message_id to read older messages.", fields: { child: childField, ...pageFields }, required: ["child"] },
];

export const agentToolsPlugin = {
    name: "agent-tools",
    /** @param {import("yuke:ext").Context} ctx */
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
                            return client.sessionSendInput(child.session.id, required(args, "message"), { session_id: parentId, message_id: context.messageId, part_id: context.partId });
                        }
                        if (definition.name === "stop_agent") return client.sessionCancelRun(child.session.id, true);
                        const page = await client.sessionHistory({ session_id: child.session.id, before_message_id: integer(args.before_message_id, 0, 0, Number.MAX_SAFE_INTEGER), limit: integer(args.limit, 20, 1, 50) });
                        const next_before_message_id = page.has_more && page.messages.length ? Math.min(...page.messages.map((message) => message.id)) : null;
                        return { messages: page.messages, has_more: page.has_more, next_before_message_id };
                    },
                });
            } catch (error) {
                if (/** @type {Error} */ (error).message !== "another tool already has this name") throw error;
            }
        }
    },
};
