import { plugins } from "yuke:internal/ext";
import { client } from "yuke:internal/client";
import { config } from "yuke:internal/kernel";
config.systemPrompt = "base prompt";
const prompts = [];
plugins.use({ name: "inspect-prompt", apply(ctx) {
  ctx.hook("input.before", (input) => { prompts.push(input.create.system_prompt); return { block: "test" }; });
} });
(async () => {
  const params = { workspace_path: "/work", child: { name: "child", site: {} }, initial_input: { type: "content", content: [{ type: "text", text: "task" }] } };
  for (const value of [params, { ...params, system_prompt: "custom" }]) {
    try { await client.request("session.create", value); throw new Error("input was not blocked"); }
    catch (error) { if (error.code !== "bad_request") throw error; }
  }
  if (prompts[0] !== undefined) throw new Error("unexpected JS prompt");
  if (prompts[1] !== "custom") throw new Error("lost custom prompt");
  globalThis.result = "ok";
})().catch((error) => globalThis.result = error.message);
