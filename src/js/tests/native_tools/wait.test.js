import { defineTool } from "yuke:tools";
import { native } from "yuke:interaction-native";
globalThis.seen = "pending";
defineTool("wait", { description: "Wait", parameters: { type: "object", properties: {} }, execute: async (args, signal) => {
  native.watchCancellation(7, signal).then(() => { globalThis.seen = "canceled"; }, (e) => { globalThis.seen = "failed: " + e.message; });
  return new Promise(() => {});
} });
