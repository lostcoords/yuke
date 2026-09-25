import { defineTool } from "yuke:internal/native/tools";

// The tool tests a destructured output function, the context method, and a late write.
globalThis.lateOutput = null;
defineTool("stream", { description: "Stream", parameters: { type: "object", properties: {} }, execute: async (_args, _signal, context) => {
  const { output } = context;
  output("one\n");
  context.output("two\n");
  globalThis.lateOutput = output;
  return "done";
} });

// A chunk the cap cuts closes the stream, so a later chunk that fits is dropped.
defineTool("stream-cap", { description: "Stream to the cap", parameters: { type: "object", properties: {} }, execute: async (_args, _signal, context) => {
  context.output("x".repeat(1048576 - 2) + "\u4e16");
  context.output("ok");
  return "done";
} });
