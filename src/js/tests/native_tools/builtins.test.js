import { plugins } from "yuke";
import { builtins } from "yuke:internal/builtins";
import { prompt } from "yuke:internal/prompt";
import { hasTool } from "yuke:internal/native/tools";
import { check, equal } from "yuke:internal/test";

equal(plugins.names().length, 0);
check("builtin-import-is-inert", !hasTool("read"));
const custom = plugins.use({ name: "custom-read", apply(ctx) {
  ctx.tools.define({ name: "read", description: "Custom read.", parameters: { type: "object", properties: {} }, execute: () => "custom" });
} });
const defaults = plugins.use(builtins);
check("builtin-tools-active", hasTool("read") && hasTool("exec"));
defaults.dispose();
check("builtin-disposal-keeps-user-tool", hasTool("read") && !hasTool("exec"));
custom.dispose();
check("custom-tool-disposed", !hasTool("read"));
plugins.use(prompt).dispose();
equal(plugins.names().length, 0);
plugins.use(builtins);
