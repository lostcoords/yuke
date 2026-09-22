import { check } from "yuke:test";
import { defineTool } from "yuke:tools";
import { cancel, listen } from "yuke:cancellation-native";
import { native } from "yuke:interaction-native";

defineTool("probe", {
  description: "Refuse work after cancellation.",
  parameters: { type: "object", properties: {} },
  execute: async (_, signal) => {
    cancel(signal);
    let refused = false;
    try { listen(signal, () => {}); } catch { refused = true; }
    check("a canceled signal takes no listener", refused);
    const results = await Promise.allSettled([
      native.request(2, JSON.stringify({ type: "confirm", title: "Allow", message: "Task" }), signal),
    ]);
    check("the interaction is refused", results.every(result => result.status === "rejected"));
    return "refused";
  },
});
