import { checkArguments } from "yuke:internal/arguments";
import { bindCall } from "yuke:internal/call";
import { hostOperation } from "yuke:internal/events";
import { type Registration, register, type ToolOwner } from "yuke:internal/native";
import type { Infer, ObjectSchema, Tool, ToolContext } from "yuke:tools";

/** The jobs of a built-in tool, which uses none of them. */
const NO_JOBS: ToolContext["jobs"] = {
  run: () => Promise.reject(new Error("a built-in tool has no jobs")),
};

/**
 * Register `tool` for its owner, or for every session without an owner.
 * Return its id and the plugin whose definition it replaces.
 */
export function defineTool<const S extends ObjectSchema>(
  tool: Tool<S>,
  owner?: ToolOwner,
  jobsOf: (signal: AbortSignal) => ToolContext["jobs"] = () => NO_JOBS,
): Registration {
  const execute = tool.execute;
  const inputSchema = tool.inputSchema;
  // Rust validates each field and fills the defaults.
  const description = {
    name: tool.name,
    description: tool.description,
    inputSchema: JSON.stringify(inputSchema),
    concurrency: tool.concurrency,
    deferLoading: tool.deferLoading,
    hints: tool.hints,
    owner,
  };
  return register(description, (request) =>
    hostOperation(async (signal, abort) => {
      const { arguments: args, sessionId, callId, folder, output, call } = request;
      const context: ToolContext = { sessionId, callId, folder, signal, output, jobs: jobsOf(signal) };
      bindCall(context, call);
      try {
        const result = await execute(checkArguments(inputSchema, args) as Infer<S>, context);
        return typeof result === "string" ? { text: result } : result;
      } finally {
        abort("The tool call has ended");
      }
    }, "The tool call was cancelled"),
  );
}
