import { plugins } from "yuke:ext";
const params = { type: "object", properties: {} };

plugins.use({
  name: "toolbox",
  apply(ctx) {
    ctx.tools.define({ name: "zeta", description: "d", parameters: params, execute: async () => ({ text: "z" }) });
    ctx.tools.define({ name: "alpha", description: "d", parameters: params, execute: async () => ({ text: "a" }) });
  },
});
