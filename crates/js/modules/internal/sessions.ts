// The sessions, the catalog, the credentials, and the plugin manager of yuke for the plugins: `ctx.get("sessions")`,
// `ctx.get("catalog")`, `ctx.get("auth")`, and `ctx.get("plugins")`.

import { underStop } from "yuke:internal/events";
import {
  authCancelLogin,
  authLogin,
  authLogout,
  authSetApiKey,
  authWaitForLogin,
  catalogList,
  type ViewEvent as NativeViewEvent,
  pluginsAdd,
  pluginsApply,
  pluginsCheck,
  pluginsList,
  pluginsRemove,
  pluginsSync,
  sessionBackground,
  sessionCancel,
  sessionClose,
  sessionHasMovable,
  sessionIdle,
  sessionInput,
  sessionJobs,
  sessionMcpServers,
  sessionNotify,
  sessionPutBlob,
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
  sessionsRename,
} from "yuke:internal/native";
import type { Auth, Catalog, OpenOptions, PluginManager, SessionHandle, Sessions, ViewEvent } from "yuke:plugins";
import type { LoginOutcome, SessionId } from "yuke:protocol";

const { reportError } = globalThis;

/** Where the events of one view go: its snapshot once, then each update, then the close of its session. */
interface Route {
  readonly event: (event: ViewEvent) => void;
  readonly closed: () => void;
}

/** The route of each view of this runtime, by its key. */
const routes = new Map<number, Route>();
let lastKey = 0;
let listening = false;

/** Give `event` to its view. A view that ended gets nothing. */
function deliver(key: number, event: NativeViewEvent): void {
  const route = routes.get(key);
  if (route === undefined) return;
  if (event === "closed") {
    route.closed();
    return;
  }
  try {
    route.event(event);
  } catch (error) {
    reportError(error);
  }
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
  // The route comes before the open, so the snapshot finds it.
  routes.set(key, {
    event: options.onEvent,
    closed: () => end(new Error(`the session ${id} closed`)),
  });
  try {
    await sessionsOpen([key, id, options.tail]);
    ended.signal.throwIfAborted();
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
    async sendMessage(content, modelContent) {
      live();
      return sessionInput([id, content, modelContent ?? null]);
    },
    async notifyModel(display, text) {
      live();
      return sessionNotify([id, plugin, display, text]);
    },
    cancel() {
      live();
      sessionCancel(id);
    },
    moveJobsToBackground() {
      live();
      sessionBackground(id);
    },
    canMoveJobsToBackground() {
      live();
      return sessionHasMovable(id);
    },
    async waitForIdle() {
      live();
      await sessionIdle(id);
    },
    async setSettings(settings) {
      live();
      await sessionSetSettings([id, settings]);
    },
    async putBlob(bytes) {
      live();
      return await sessionPutBlob(id, bytes);
    },
    async removeInput(inputId) {
      live();
      return await sessionRemoveInput([id, inputId]);
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
      await sessionStopJob([id, jobId]);
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
    create: (settings, options) => sessionsCreate([settings, options?.parent ?? null]),
    fork: (id, through) => sessionsFork([id, through ?? null]),
    list: (params) => sessionsList(params ?? {}),
    get: (id) => sessionsGet(id),
    async rename(id, title) {
      await sessionsRename([id, title]);
    },
    async remove(id) {
      await sessionsRemove(id);
    },
    open: (id, options) => open(plugin, signal, id, options),
    events: (id, page) => sessionsEvents([id, page.before ?? null, page.limit]),
    async closeForAll(id) {
      await sessionClose(id);
    },
  } satisfies Sessions);
}

/** The catalog of the providers and their models. */
export const catalog: Catalog = Object.freeze({
  list: (options) => catalogList(options?.all === true),
} satisfies Catalog);

/** The credentials of the providers. */
export const auth: Auth = Object.freeze({
  async login(provider, options) {
    const signal = options?.signal;
    signal?.throwIfAborted();
    const started = await authLogin(provider);
    const cancel = (): void => authCancelLogin(started.loginId);
    if (signal?.aborted) cancel();
    else signal?.addEventListener("abort", cancel, { once: true });
    let end: Promise<LoginOutcome> | undefined;
    return Object.freeze({
      verificationUrl: started.verificationUrl,
      userCode: started.userCode,
      waitForEnd: () => {
        end ??= authWaitForLogin(started.loginId);
        return end;
      },
    });
  },
  setApiKey: (provider, apiKey) => authSetApiKey({ provider, apiKey }),
  logout: (provider) => authLogout(provider),
} satisfies Auth);

/** The plugin manager of the profile. */
export const plugins: PluginManager = Object.freeze({
  list: () => pluginsList(null),
  sync: (options) => underStop(options?.signal, () => pluginsSync({ locked: options?.locked === true })),
  check: (target, options) => underStop(options?.signal, () => pluginsCheck({ target })),
  apply: (changes) => pluginsApply({ changes: [...changes] }),
  add: (plugin, options) => underStop(options?.signal, () => pluginsAdd(plugin)),
  async remove(name) {
    await pluginsRemove({ name });
  },
} satisfies PluginManager);
