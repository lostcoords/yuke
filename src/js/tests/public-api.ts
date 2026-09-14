import { tools, fs } from "yuke";
import type { Context, ToolDefinition, ToolExecute } from "yuke";

declare const ctx: Context;
declare const tool: ToolDefinition;
declare const site: Parameters<ToolExecute>[2];
const fields: [string, string | undefined, number | undefined, number | undefined] = [site.workspaceRoot, site.sessionId, site.messageId, site.partId];
const rootOff: () => void = tools.define(tool);
const pluginOff: () => void = ctx.tools.define(tool);
ctx.advise(fs, "readFile", "before", () => {});
// @ts-expect-error Advice kinds form a closed set.
ctx.advise(fs, "readFile", "invalid", () => {});
// @ts-expect-error A plugin has no terminal capability before inject.
ctx.tui.status({ render: () => "note" });
ctx.inject(["tui"], (ctx) => {
  ctx.tui.status({ render: () => "note" });
  // @ts-expect-error The terminal surface has no such method.
  ctx.tui.invalid();
});
ctx.inject(["custom"], (ctx) => {
  const value: unknown = ctx.custom;
  // @ts-expect-error This block did not request tui.
  ctx.tui.status({ render: () => "note" });
});
