import { client } from "yuke:internal/client";
globalThis.client = client;
globalThis.stats = { creates: 0 };
client.sessionCreate = async (params) => { stats.creates++; globalThis.created = params; return { session: { id: "02".repeat(16), model: params.model }, input: { type: "queued", input_id: 1, reason: "concurrency_limit" } }; };
globalThis.result = "pending";
