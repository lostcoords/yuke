import { plugins, createSession } from "yuke:ext";
import { config } from "yuke:kernel";
config.systemPrompt = "base prompt";
const prompts = [];
plugins.use({ name: "inspect-prompt", apply(ctx) {
  ctx.hook("input.before", (input) => { prompts.push(input.create.system_prompt); return { block: "test" }; });
} });
(async () => {
  const params = { workspace_path: "/work", child: { name: "child", slot: "small", site: {} }, initial_input: { type: "content", content: [{ type: "text", text: "task" }] } };
  for (const value of [params, { ...params, system_prompt: "custom" }]) {
    try { await createSession(value); throw new Error("input was not blocked"); }
    catch (error) { if (error.code !== "bad_request") throw error; }
  }
  if (prompts[0] !== undefined) throw new Error("unexpected JS prompt");
  if (prompts[1] !== "custom") throw new Error("lost custom prompt");
  globalThis.result = "ok";
})().catch((error) => globalThis.result = error.message);
