import { defineTool } from "yuke:tools";
import { exec } from "yuke:exec";
globalThis.refusals = 0;
globalThis.prelaunch = 0;
globalThis.late = 0;
for (const signal of [null, false, {}, { aborted: false }]) {
  exec("echo forbidden > forbidden", { signal }).catch(() => { globalThis.refusals++; });
}
defineTool("probe", {
  description: "Probe exec cancellation.", parameters: { type: "object", properties: {} },
  execute: async (args, signal) => {
    globalThis.retained = signal;
    globalThis.resume = () => exec("echo forbidden > forbidden", { signal }).catch(() => { globalThis.late++; });
    return Promise.all([1, 2].map(() => exec("echo forbidden > forbidden", { signal }).catch(() => { globalThis.prelaunch++; })));
  },
});
