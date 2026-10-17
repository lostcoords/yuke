import { checkArguments, checkParameters } from "yuke:internal/arguments";
import { hostSignal } from "yuke:internal/events";
import { register } from "yuke:internal/native";
import { bindSession } from "yuke:internal/session";
import type { Tool, ToolAnswer, ToolContext } from "yuke:tools";

/**
 * Define `tool` for `owner`, the plugin that defines it, or for yuke itself without an owner. A second tool with the
 * same name throws a `TypeError`. A plugin defines its tools with `ctx.tools.define`.
 */
export function defineTool(tool: Tool, owner?: string): void {
  const execute = tool.execute;
  if (typeof execute !== "function") throw new TypeError("execute is not a function");
  // The model and the argument check use this one checked copy, so a later change of `tool` changes neither.
  const text = JSON.stringify(tool.parameters) as string | undefined;
  const parameters: unknown = text === undefined ? undefined : JSON.parse(text);
  checkParameters(parameters);
  const description = {
    name: tool.name,
    description: tool.description,
    parameters: JSON.stringify(parameters),
    concurrency: tool.concurrency,
    defer: tool.defer === true,
    owner,
  };
  register(description, (text, callId, folder, output, session) => {
    const { signal, abort } = hostSignal();
    const context: ToolContext = { callId, folder, signal, output };
    bindSession(context, session);
    const answer = run(() => execute(checkArguments(parameters, JSON.parse(text)), context), abort);
    return { answer, abort: () => abort("The tool call was cancelled") };
  });
}

async function run(
  call: () => ToolAnswer | Promise<ToolAnswer>,
  abort: (message: string) => void,
): Promise<ToolAnswer> {
  try {
    return await call();
  } finally {
    abort("The tool call has ended");
  }
}
