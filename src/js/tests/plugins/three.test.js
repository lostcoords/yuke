import { plugins } from "yuke:ext";
const params = { type: "object", properties: {} };
globalThis.drop = null;
plugins.use({
  name: "three",
  apply(ctx) {
    ctx.tools.define({ name: "zulu", description: "d", parameters: params, execute: async () => ({ text: "z" }) });
    globalThis.drop = ctx.tools.define({ name: "bravo", description: "d", parameters: params, execute: async () => ({ text: "b" }) });
    ctx.tools.define({ name: "alpha", description: "d", parameters: params, execute: async () => ({ text: "a" }) });
    ctx.tools.define({ name: "mike", description: "d", parameters: params, execute: async () => ({ text: "m" }) });
  },
});
