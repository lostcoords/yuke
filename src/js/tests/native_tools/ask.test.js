import { defineTool } from "yuke:internal/native/tools";
import { native } from "yuke:internal/native/interaction";
defineTool("ask", { description: "Ask", parameters: { type: "object", properties: {} }, execute: async (args, signal, context) => {
  globalThis.site = context.sessionId === "01".repeat(16) && context.messageId === 4 && context.partId === 2;
  return native.request(99, JSON.stringify({ type: "confirm", title: "Allow", message: "Task" }), signal);
} });
