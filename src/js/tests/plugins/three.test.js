import { plugins } from "yuke:internal/ext";
const params = { type: "object", properties: {} };
globalThis.drop = null;
plugins.use({
  name: "three",
  apply(ctx) {
    ctx.tools.define({ name: "zulu", description: "d", parameters: params, execute: async () => "z" });
    globalThis.drop = ctx.tools.define({ name: "bravo", description: "d", parameters: params, execute: async () => "b" });
    ctx.tools.define({ name: "alpha", description: "d", parameters: params, execute: async () => "a" });
    ctx.tools.define({ name: "mike", description: "d", parameters: params, execute: async () => "m" });
  },
});
