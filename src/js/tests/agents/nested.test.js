import "yuke:kernel";
import { spawnAgent } from "yuke:agents";
const child = "02".repeat(16);
client.sessionGet = async (id) => ({ session: { id, root: "/work", origin: { type: "child", site: { session_id: "01".repeat(16) } } } });
client.sessionCreate = async (params) => { globalThis.created = params; return { session: { id: child, model: "native/model" }, input: { type: "queued" } }; };
const spawned = await spawnAgent(ctx, { name: "b", message: "task", model: "small" }, undefined, { sessionId: child, messageId: 1, partId: 0 });
if (spawned.name !== "b" || spawned.model !== "native/model" || created.model || created.reasoning) throw new Error("native admission");
globalThis.result = "ok";
