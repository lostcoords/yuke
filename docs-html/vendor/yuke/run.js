// One-shot: create a session, send a prompt, wait for run.done, return text.
// Owns subscription.set on this Client — do not compose with attach() on the
// same connection. Permission prompts hang unless `permission` is set
// (typically "yolo").
import { ClosedError } from "./errors.js";
import { SessionReplica } from "./session.js";
export async function run(opts) {
    const prompt = opts.prompt.trim();
    if (prompt.length === 0) {
        throw new Error("run: prompt is empty");
    }
    const ac = new AbortController();
    const onOuterAbort = () => ac.abort();
    if (opts.signal?.aborted === true)
        ac.abort();
    else
        opts.signal?.addEventListener("abort", onOuterAbort, { once: true });
    try {
        const rpc = { signal: ac.signal };
        const created = await opts.client.request("session.create", createParams(opts), rpc);
        const sessionId = created.session.id;
        const replica = new SessionReplica(sessionId);
        // Queue must exist before subscribe/send so a fast run.done is not dropped.
        const stream = opts.client.broadcasts({ signal: ac.signal });
        await opts.client.request("subscription.set", { sessions: [sessionId] }, rpc);
        replica.installSnapshot(await opts.client.request("session.resync", { session_id: sessionId }, rpc));
        let outcome = null;
        const pump = (async () => {
            try {
                for await (const event of stream) {
                    const result = replica.applyBroadcast(event);
                    if (result.kind === "gap") {
                        replica.installSnapshot(await opts.client.request("session.resync", { session_id: sessionId }, rpc));
                    }
                    if (event.method === "run.done" && event.params.session_id === sessionId) {
                        outcome = event.params.outcome;
                        break;
                    }
                }
            }
            catch (error) {
                if (error instanceof ClosedError)
                    return;
                throw error;
            }
        })();
        try {
            await opts.client.request("session.send_input", {
                session_id: sessionId,
                input: { type: "content", content: [{ type: "text", text: prompt }] },
            }, rpc);
            await pump;
        }
        finally {
            ac.abort();
            await pump.catch(() => undefined);
        }
        if (outcome === null) {
            throw new Error("run: connection closed before run.done");
        }
        return { sessionId, text: assistantText(replica.messages), outcome };
    }
    finally {
        opts.signal?.removeEventListener("abort", onOuterAbort);
        if (!ac.signal.aborted)
            ac.abort();
    }
}
function createParams(opts) {
    return {
        ...(opts.workspace_path !== undefined ? { workspace_path: opts.workspace_path } : {}),
        ...(opts.profile !== undefined ? { profile: opts.profile } : {}),
        ...(opts.model !== undefined ? { model: opts.model } : {}),
        ...(opts.reasoning !== undefined ? { reasoning: opts.reasoning } : {}),
        ...(opts.system_prompt !== undefined ? { system_prompt: opts.system_prompt } : {}),
        ...(opts.permission !== undefined ? { permission: opts.permission } : {}),
        ...(opts.max_rounds !== undefined ? { max_rounds: opts.max_rounds } : {}),
    };
}
function assistantText(messages) {
    const parts = [];
    for (const message of messages) {
        if (message.type !== "assistant")
            continue;
        for (const part of message.content) {
            if (part.type === "text")
                parts.push(part.text);
        }
    }
    return parts.join("");
}
//# sourceMappingURL=run.js.map