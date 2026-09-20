import { defineConfig, config, plugins } from "yuke";
defineConfig({ keymap: { chordMs: 500 } });
plugins.use({ name: "from-facade", apply(ctx) {
  ctx.tools.define({
    name: "facade_tool",
    description: "Registered through the facade.",
    parameters: { type: "object", properties: {} },
    execute: async () => ({ text: "ok" }),
  });
} });
globalThis.named = plugins.names().join(",");
globalThis.chord = config.keymap.chordMs;
