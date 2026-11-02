// The facts of `ctx.on`: one watch of the host for the runtime while a listener exists. The host sends nothing while
// no listener exists.

import { failureOf } from "yuke:internal/failure";
import { type Fact, factsListen, factsRelease, factsWatch, notify } from "yuke:internal/native";
import { frozen } from "yuke:internal/values";
import type { HostEvents } from "yuke:plugins";
import type { InteractionId, SessionId, SessionState } from "yuke:protocol";

type Event = keyof HostEvents;

const EVENTS: readonly string[] = [
  "session.update",
  "session.opened",
  "session.closed",
  "notice",
  "theme.changed",
] satisfies Event[];

/** The event that starts in this runtime. Its listeners need no watch of the host. */
const LOCAL: Event = "theme.changed";

interface Listener {
  readonly plugin: string;
  readonly event: Event;
  readonly signal: AbortSignal;
  readonly call: (data: never) => void;
}

const listeners = new Set<Listener>();
/** The open sessions of the watch, so a later listener of `session.opened` gets them too. */
const open = new Map<SessionId, { state: SessionState; questions: InteractionId[] }>();
/** The key of the watch now, or 0 without a watch. A fact of an older watch counts for nothing. */
let key = 0;
let lastKey = 0;
let listening = false;

/** Keep the open sessions of the watch in step with `fact`. */
function track(fact: Fact): void {
  if (fact.event === "session.opened") {
    open.set(fact.data.sessionId, { state: fact.data.state, questions: [...fact.data.questions] });
  } else if (fact.event === "session.closed") {
    open.delete(fact.data.sessionId);
  } else if (fact.event === "session.update") {
    const session = open.get(fact.data.sessionId);
    const update = fact.data.update;
    if (session === undefined) return;
    if (update.sessionUpdate === "state") session.state = update.state;
    else if (update.sessionUpdate === "interaction_requested") session.questions.push(update.interactionId);
    else if (update.sessionUpdate === "interaction_closed") {
      session.questions = session.questions.filter((id) => id !== update.interactionId);
    }
  }
}

/** Give `data` to `listener`. A throw removes the listener and gives a notice of its plugin. */
function call(listener: Listener, data: unknown): void {
  try {
    listener.call(data as never);
  } catch (error) {
    remove(listener);
    notify(listener.plugin, "error", `a listener of ${listener.event} failed: ${failureOf(error)}`, undefined);
  }
}

/** Give each fact of `batch` to the listeners of its event, in order. */
function deliver(batch: readonly (readonly [number, Fact])[]): void {
  for (const [from, fact] of batch) {
    if (from !== key) continue;
    track(fact);
    const data = frozen(fact.data);
    for (const listener of [...listeners]) {
      // A listener that an earlier one removed gets nothing more.
      if (listener.event === fact.event && listeners.has(listener)) call(listener, data);
    }
  }
}

/**
 * Give `data` to the listeners of `event`, for a fact that starts in this runtime and not in the host. The abort of a
 * plugin can cause the fact, so a listener of that plugin gets nothing.
 */
export function announce<K extends Event>(event: K, data: HostEvents[K]): void {
  const shown = frozen(data);
  for (const listener of [...listeners]) {
    if (listener.event === event && listeners.has(listener) && !listener.signal.aborted) call(listener, shown);
  }
}

/** Remove `listener`. The last removal ends the watch. */
function remove(listener: Listener): void {
  if (!listeners.delete(listener) || key === 0 || [...listeners].some((other) => other.event !== LOCAL)) return;
  factsRelease();
  key = 0;
  open.clear();
}

/** Add `listener` of the plugin `plugin` for `event`, until the remover runs or `signal` aborts. */
export function on<K extends Event>(
  plugin: string,
  signal: AbortSignal,
  event: K,
  listener: (data: HostEvents[K]) => void,
): () => void {
  if (!EVENTS.includes(event)) throw new TypeError(`on: '${String(event)}' is not an event`);
  if (typeof listener !== "function") throw new TypeError("on: the listener is no function");
  if (signal.aborted) return () => {};
  const entry: Listener = { plugin, event, signal, call: listener as (data: never) => void };
  listeners.add(entry);
  if (event !== LOCAL) {
    if (!listening) {
      factsListen(deliver);
      listening = true;
    }
    if (key === 0) {
      lastKey += 1;
      key = lastKey;
      factsWatch(key);
    }
  }
  const stop = (): void => {
    signal.removeEventListener("abort", stop);
    remove(entry);
  };
  signal.addEventListener("abort", stop, { once: true });
  // A new watch gives its open sessions as facts. A watch that runs already knows them.
  if (event === "session.opened") {
    for (const [sessionId, session] of open) {
      if (listeners.has(entry)) {
        call(entry, frozen({ sessionId, state: session.state, questions: [...session.questions] }));
      }
    }
  }
  return stop;
}
