import type { Session } from "yuke:internal/native";
import type { ToolContext } from "yuke:tools";

/** The session object of each call, by its context. A tool of a plugin cannot import this module, so it cannot reach it. */
const sessions = new WeakMap<ToolContext, Session>();

/** Keep `session` for the call of `context`. */
export function bindSession(context: ToolContext, session: Session): void {
  sessions.set(context, session);
}

/** The session object of the call of `context`. */
export function sessionOf(context: ToolContext): Session {
  const session = sessions.get(context);
  if (session === undefined) throw new Error("the context belongs to no call");
  return session;
}
