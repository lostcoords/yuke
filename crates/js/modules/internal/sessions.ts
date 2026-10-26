// The sessions and the catalog of yuke for the plugins: `ctx.get("sessions")` and `ctx.get("catalog")`.

import {
  catalogList,
  sessionCancel,
  sessionClose,
  sessionIdle,
  sessionInput,
  sessionJobs,
  sessionMcpServers,
  sessionNotify,
  sessionRemoveInput,
  sessionRespond,
  sessionSetSettings,
  sessionStopJob,
  sessionsCreate,
  sessionsEvents,
  sessionsFork,
  sessionsGet,
  sessionsList,
  sessionsListen,
  sessionsOpen,
  sessionsRelease,
  sessionsRemove,
  type ViewEvent,
} from "yuke:internal/native";
import type { Catalog, OpenOptions, SessionHandle, Sessions } from "yuke:plugins";
import type { SessionId, SessionSnapshot, SessionUpdate } from "yuke:protocol";

const { reportError } = globalThis;

/** Where the events of one view go: its snapshot once, then each update, then the close of its session. */
interface Route {
  snapshot: ((snapshot: SessionSnapshot) => void) | undefined;
  readonly update: (update: SessionUpdate) => void;
  readonly closed: () => void;
}

/** The route of each view of this runtime, by its key. */
const routes = new Map<number, Route>();
let lastKey = 0;
let listening = false;

/** Give each event of `batch` to its view. A view that ended gets nothing. */
function deliver(batch: readonly (readonly [number, ViewEvent])[]): void {
  for (const [key, event] of batch) {
    const route = routes.get(key);
    if (route === undefined) continue;
    if ("closed" in event) {
      route.closed();
      continue;
    }
    if ("snapshot" in event) {
      route.snapshot?.(event.snapshot);
      route.snapshot = undefined;
      continue;
    }
    try {
      route.update(event.update);
    } catch (error) {
      reportError(error);
    }
  }
}

/** `promise`, or a rejection with the reason of `signal` when it aborts first. */
function untilAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const abort = (): void => reject(signal.reason);
    signal.addEventListener("abort", abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}

/** Open session `id` for the plugin `plugin`, whose signal also ends the handle. */
async function open(
  plugin: string,
  pluginSignal: AbortSignal,
  id: SessionId,
  options: OpenOptions,
): Promise<SessionHandle> {
  const signal = options.signal === undefined ? pluginSignal : AbortSignal.any([pluginSignal, options.signal]);
  signal.throwIfAborted();
  if (!listening) {
    sessionsListen(deliver);
    listening = true;
  }
  lastKey += 1;
  const key = lastKey;
  const ended = new AbortController();
  const end = (reason: unknown): void => {
    if (ended.signal.aborted) return;
    signal.removeEventListener("abort", stop);
    routes.delete(key);
    sessionsRelease(key);
    ended.abort(reason);
  };
  const stop = (): void => end(signal.reason);
  signal.addEventListener("abort", stop, { once: true });
  const snapshot = Promise.withResolvers<SessionSnapshot>();
  // The route comes before the open, so the snapshot finds it.
  routes.set(key, {
    snapshot: snapshot.resolve,
    update: options.update,
    closed: () => end(new Error(`the session ${id} closed`)),
  });
  let first: SessionSnapshot;
  try {
    await sessionsOpen([key, id, options.tail]);
    first = await untilAbort(snapshot.promise, ended.signal);
  } catch (error) {
    end(error);
    // The handle can end before the native open stores its hold.
    sessionsRelease(key);
    throw error;
  }
  const live = (): void => {
    if (ended.signal.aborted) throw new Error(`the handle of the session ${id} has ended`);
  };
  return Object.freeze({
    id,
    signal: ended.signal,
    snapshot: first,
    async input(content) {
      live();
      return sessionInput([id, content]);
    },
    async notify(display, text) {
      live();
      return sessionNotify([id, plugin, String(display), String(text)]);
    },
    cancel() {
      live();
      sessionCancel(id);
    },
    async idle() {
      live();
      await sessionIdle(id);
    },
    async setSettings(settings) {
      live();
      await sessionSetSettings([id, settings]);
    },
    async removeInput(inputId) {
      live();
      await sessionRemoveInput([id, inputId]);
    },
    respond(interactionId, response) {
      live();
      sessionRespond([id, interactionId, response]);
    },
    jobs() {
      live();
      return sessionJobs(id);
    },
    async stopJob(jobId) {
      live();
      await sessionStopJob([id, String(jobId)]);
    },
    mcpServers() {
      live();
      return sessionMcpServers(id);
    },
  } satisfies SessionHandle);
}

/** The sessions for the plugin `plugin`. Its signal ends each handle that it opened. */
export function sessionsOf(plugin: string, signal: AbortSignal): Sessions {
  return Object.freeze({
    create: (settings) => sessionsCreate(settings),
    fork: (id, through) => sessionsFork([id, through ?? null]),
    list: (params) => sessionsList(params ?? {}),
    get: (id) => sessionsGet(id),
    async remove(id) {
      await sessionsRemove(id);
    },
    open: (id, options) => open(plugin, signal, id, options),
    events: (id, page) => sessionsEvents([id, page.before ?? null, page.limit]),
    async close(id, options) {
      await sessionClose([id, options?.stopJobs === true]);
    },
  } satisfies Sessions);
}

/** The catalog of the providers and their models. */
export const catalog: Catalog = Object.freeze({
  list: (options) => catalogList(options?.all === true),
} satisfies Catalog);
