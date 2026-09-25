import { defineTool } from "yuke:internal/native/tools";
import * as cancellation from "yuke:internal/native/cancellation";
globalThis.seen = "pending";
defineTool("wait", { description: "Wait", parameters: { type: "object", properties: {} }, execute: async (args, signal) => {
  cancellation.listen(signal, () => { globalThis.seen = "canceled"; });
  // A removed listener never hears the cancel.
  cancellation.unlisten(cancellation.listen(signal, () => { globalThis.seen = "removed listener heard"; }));
  return new Promise(() => {});
} });
