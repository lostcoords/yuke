import { plugins } from "yuke:ext";
const params = { type: "object", properties: {} };
plugins.use({ name: "again", apply: (ctx) => {
  ctx.tools.define({ name: "zeta", description: "d", parameters: params, execute: async () => ({ text: "z2" }) });
} });
