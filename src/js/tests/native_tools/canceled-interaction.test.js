import { check } from "yuke:test";
import { defineTool } from "yuke:tools";
import { cancel } from "yuke:cancellation-native";
import { native } from "yuke:interaction-native";

defineTool("probe", {
  description: "Refuse work after cancellation.",
  parameters: { type: "object", properties: {} },
  execute: async (_, signal) => {
    cancel(signal);
    const results = await Promise.allSettled([
      native.watchCancellation(1, signal),
      native.request(2, JSON.stringify({ type: "confirm", title: "Allow", message: "Task" }), signal),
    ]);
    check("both interactions are refused", results.every(result => result.status === "rejected"));
    return "refused";
  },
});
