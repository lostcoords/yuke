import { defineTool } from "yuke:tools";
const params = { type: "object", properties: { city: { type: "string", description: "The city." } } };
defineTool("throws", { description: "d", parameters: params, execute: async () => { throw new Error("it broke"); } });
defineTool("cycles", { description: "d", parameters: params, execute: async () => { const o = {}; o.self = o; return o; } });
