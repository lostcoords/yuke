import { defineTool } from "yuke:tools";
// This handler never settles, so only the close can answer the waiting turn.
defineTool("hangs", {
  description: "d",
  parameters: { type: "object", properties: { city: { type: "string", description: "The city." } } },
  execute: async () => new Promise(() => {}),
});
