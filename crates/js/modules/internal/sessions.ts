// The sessions and the catalog of yuke for the plugins, `ctx.get("sessions")` and `ctx.get("catalog")`, and the
// credentials and the plugin manager for the bundled plugins `login` and `plugins`.

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
import type { Catalog, OpenOptions, SessionHandle, SessionHandleEvent, Sessions } from "yuke:plugins";
import type {
  AddPluginParams,
  AddPluginResult,
  ApplyPluginsResult,
  CheckPluginsResult,
  ListPluginsResult,
  LoginOutcome,
  PluginChange,
  PluginTarget,
  SessionId,
  SyncPluginsResult,
} from "yuke:protocol";

/** Where the events of one view go: its snapshot once, then each update, then the close of its session. */
interface Route {
  readonly event: (event: SessionHandleEvent) => void;
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
  route.event(event);
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
  const close = (): void => end(new DOMException(`the handle of the session ${id} closed`, "AbortError"));
  return Object.freeze({
    id,
    signal: ended.signal,
    async sendMessage(message) {
      live();
      return sessionInput([id, message.content, message.modelContent ?? null]);
    },
    async notifyModel(notification) {
      live();
      return sessionNotify([id, plugin, notification.display, notification.text]);
    },
    close,
    [Symbol.dispose]: close,
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

/** A device login that has started. The user opens the URL and enters the code. */
export interface LoginInProgress {
  readonly verificationUrl: string;
  readonly userCode: string;
  /** Wait for the end of the login, and give its outcome. A login that has ended gives its outcome too. */
  readonly waitForEnd: () => Promise<LoginOutcome>;
}

/** The credentials of the providers, for the bundled plugin `login`, as the requests `auth/login`, `auth/set_api_key`, and `auth/logout` do. */
export interface Auth {
  /**
   * Start a device login of `provider`. A new login of the provider ends the login before it as `cancelled`.
   * `options.signal` cancels the login. The stored login stays in `auth.json` until the new login saves.
   */
  readonly login: (provider: string, options?: { readonly signal?: AbortSignal }) => Promise<LoginInProgress>;
  /** Store `apiKey` in `auth.json`. The new key replaces the stored key and wins over the variable of the provider. */
  readonly setApiKey: (provider: string, apiKey: string) => Promise<void>;
  /** Remove what yuke stored for `provider`. yuke revokes nothing at the provider. */
  readonly logout: (provider: string) => Promise<void>;
}

/**
 * The plugin manager of the profile, for the bundled plugin `plugins`, as the requests `plugin/list`, `plugin/sync`, `plugin/check`, `plugin/apply`,
 * `plugin/add`, and `plugin/remove` give it. No call runs plugin code, and a new commit loads at the next reload. Git asks for no password.
 */
export interface PluginManager {
  /** The plugins of `config.json` with their state on disk, and whether each one runs. It uses no network. */
  readonly list: () => Promise<ListPluginsResult>;
  /**
   * Install the locked commit of each Git plugin, and lock each new one at the commit of its ref. With
   * `options.locked`, the lock must match `config.json`, and it stays as it is. `options.signal` stops the work.
   */
  readonly sync: (options?: { readonly locked?: boolean; readonly signal?: AbortSignal }) => Promise<SyncPluginsResult>;
  /**
   * The new commit of each Git plugin of `target` whose ref moved, with the log of the move. Each new commit is
   * installed, and `plugins.lock` stays as it is until `apply`. `options.signal` stops the work.
   */
  readonly check: (target: PluginTarget, options?: { readonly signal?: AbortSignal }) => Promise<CheckPluginsResult>;
  /** Write the new commit of each change of `check` into `plugins.lock`. */
  readonly apply: (changes: readonly PluginChange[]) => Promise<ApplyPluginsResult>;
  /**
   * Add the Git plugin `plugin` to `config.json`, install it, and lock it at the commit of its ref. The comments of
   * `config.json` stay. `options.signal` stops the work.
   */
  readonly add: (plugin: AddPluginParams, options?: { readonly signal?: AbortSignal }) => Promise<AddPluginResult>;
  /** Remove the plugin `name` from `config.json` and `plugins.lock`. Its install stays on disk. */
  readonly remove: (name: string) => Promise<void>;
}

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
