import { defineTool } from "yuke:internal/native/tools";
defineTool("bravo", { description: "d", parameters: { type: "object", properties: {} },
  execute: async () => ({ text: "b" }) });
