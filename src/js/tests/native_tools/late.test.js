import { defineTool } from "yuke:tools";
defineTool("bravo", { description: "d", parameters: { type: "object", properties: {} },
  execute: async () => ({ text: "b" }) });
