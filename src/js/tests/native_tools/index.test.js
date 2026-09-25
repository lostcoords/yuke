import { defineTool } from "yuke:internal/native/tools";
defineTool("edit", {
  description: "The user edit tool.",
  parameters: { type: "object", properties: {} },
  execute: async () => "user edit",
});
