import { defineTool } from "yuke:tools";
import { native } from "yuke:interaction-native";
defineTool("ask", { description: "Ask", parameters: { type: "object", properties: {} }, execute: async (args, signal, context) => {
  globalThis.site = context.sessionId === "01".repeat(16) && context.messageId === 4 && context.partId === 2;
  return native.request(99, JSON.stringify({ type: "confirm", title: "Allow", message: "Task" }), signal);
} });
