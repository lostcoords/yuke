import { defineConfig, plugins, tools } from "yuke";
import { config } from "yuke:core";
defineConfig({ keymap: { chordMs: 500 } });
tools.define({
  name: "facade_tool",
  description: "Registered through the facade.",
  parameters: { type: "object", properties: {} },
  execute: async () => ({ text: "ok" }),
});
plugins.use({ name: "from-facade", apply: () => {} });
globalThis.named = plugins.names().join(",");
globalThis.chord = config.keymap.chordMs;
