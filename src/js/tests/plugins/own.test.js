import { check } from "yuke:internal/test";
import { plugins } from "yuke:internal/ext";
import { hasTool } from "yuke:internal/native/tools";
const params = { type: "object", properties: {} };

plugins.use({
  name: "toolbox",
  apply(ctx) {
    ctx.tools.define({ name: "zeta", description: "d", parameters: params, execute: async () => ({ text: "z" }) });
    ctx.tools.define({ name: "alpha", description: "d", parameters: params, execute: async () => ({ text: "a" }) });
  },
});

check("has-tool", hasTool("alpha") && !hasTool("missing"));
