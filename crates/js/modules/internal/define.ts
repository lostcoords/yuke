import { checkArguments } from "yuke:internal/arguments";
import { bindCall } from "yuke:internal/call";
import { hostOperation } from "yuke:internal/events";
import { type Answer, type Registration, register, type ToolOwner } from "yuke:internal/native";
import type { Infer, ObjectSchema, Tool, ToolContext, ToolResult } from "yuke:tools";

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
  // The model and the argument check use this one copy, so a later change of `tool` changes neither.
  const parameters = JSON.parse(JSON.stringify(tool.parameters)) as S;
  // Rust validates the hints. The default of `preview` is here because the stored form requires it.
  const hints = {
    ...(tool.hints?.title === undefined ? {} : { title: tool.hints.title }),
    ...(tool.hints?.subject === undefined ? {} : { subject: tool.hints.subject }),
    preview: tool.hints?.preview ?? "head",
  } as const;
  const description = {
    name: tool.name,
    description: tool.description,
    parameters: JSON.stringify(parameters),
    concurrency: tool.concurrency,
    deferLoading: tool.deferLoading === true,
    hints,
    owner,
  };
  return register(description, (request) =>
    hostOperation(async (signal, abort) => {
      const { arguments: args, sessionId, callId, cwd, output, call } = request;
      const context: ToolContext = { sessionId, callId, cwd, signal, output, jobs: jobsOf(signal) };
      bindCall(context, call);
      try {
        return answerOf(await execute(checkArguments(parameters, args) as Infer<S>, context));
      } finally {
        abort("The tool call has ended");
      }
    }, "The tool call was cancelled"),
  );
}

/** The result of `execute` with its defaults filled. Rust validates the fields. */
function answerOf(result: ToolResult): Answer {
  if (typeof result === "string") return { text: result, isError: false, media: [], display: [] };
  return {
    text: result.text,
    isError: result.isError ?? false,
    // A copy of the bytes now: Rust reads the answer after the abort of the call, and a listener can change the bytes.
    media: (result.media ?? []).map((item) =>
      item.bytes === undefined ? item : { mimeType: item.mimeType, bytes: new Uint8Array(item.bytes) },
    ),
    display: result.display ?? [],
  };
}
