import { defineTool } from "yuke:tools";
globalThis.seen = "none";
// The handler keeps the signal, so it reads the flag long after the call record is gone.
defineTool("watch", {
  description: "d",
  parameters: { type: "object", properties: { city: { type: "string", description: "The city." } } },
  execute: async (args, signal) => {
    globalThis.check = () => { globalThis.seen = signal.aborted ? "aborted" : "live"; };
    globalThis.check();
    // A job queued before the pass reads the flag in that pass's first drain.
    await new Promise((resolve) => { globalThis.release = resolve; });
    globalThis.check();
    return new Promise(() => {});
  },
});
