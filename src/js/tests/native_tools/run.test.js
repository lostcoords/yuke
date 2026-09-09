import { defineTool } from "yuke:tools";
const params = { type: "object", properties: { city: { type: "string", description: "The city." } } };
defineTool("sync", { description: "d", parameters: params, execute: (a) => ({ got: a.city }) });
defineTool("later", { description: "d", parameters: params, execute: async (a) => ({ got: a.city, async: true }) });
defineTool("text", { description: "d", parameters: params, execute: async () => "just text" });
defineTool("nothing", { description: "d", parameters: params, execute: async () => undefined });
