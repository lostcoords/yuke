import { defineTool } from "yuke:tools";
import { exec } from "yuke:exec";
globalThis.finished = 0;
defineTool("probe", {
  description: "Probe completed exec.", parameters: { type: "object", properties: {} },
  execute: async (args, signal) => {
    await exec("echo done", { signal });
    globalThis.finished++;
    return new Promise(() => {});
  },
});
