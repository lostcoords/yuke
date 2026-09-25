import { defineTool } from "yuke:internal/native/tools";
import { exec } from "yuke:internal/native/exec";
globalThis.finished = 0;
defineTool("probe", {
  description: "Probe completed exec.", parameters: { type: "object", properties: {} },
  execute: async (args, signal) => {
    await exec("echo done", { signal });
    globalThis.finished++;
    return new Promise(() => {});
  },
});
