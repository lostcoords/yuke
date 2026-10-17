import type { CallHost } from "yuke:internal/native";
import { PrivateMap } from "yuke:internal/webidl";
import type { ToolContext } from "yuke:tools";

/** The host of each call, by its context. A tool of a plugin cannot import this module, so it cannot reach it. */
const calls = new PrivateMap<ToolContext, CallHost>();

/** Keep `host` for the call of `context`. */
export function bindCall(context: ToolContext, host: CallHost): void {
  calls.set(context, host);
}

/** The host of the call of `context`. */
export function callOf(context: ToolContext): CallHost {
  const host = calls.get(context);
  if (host === undefined) throw new Error("the context belongs to no call");
  return host;
}
