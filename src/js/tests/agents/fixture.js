import { client } from "yuke:client";
globalThis.client = client;
globalThis.stats = { creates: 0, gets: 0 };
globalThis.parent = { session: { id: "01".repeat(16), root: "/work", model: "parent/large", origin: { type: "root" } }, activity: { state: { type: "idle" }, queued: 0 } };
client.sessionGet = async () => { stats.gets++; return parent; };
client.sessionCreate = async (params) => { stats.creates++; globalThis.created = params; return { session: { id: "02".repeat(16), model: params.model }, input: { type: "queued", input_id: 1, reason: "concurrency_limit" } }; };
globalThis.result = "pending";
