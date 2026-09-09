import { plugins } from "yuke:ext";
plugins.use({ name: "custom-agent", apply(ctx) {
  ctx.tools.define({ name: "spawn_agent", description: "custom", parameters: { type: "object", properties: {} }, execute: async () => "custom agent" });
} });
