// The sessions and the catalog of yuke for the plugins, `ctx.get("sessions")` and `ctx.get("catalog")`, and the
// credentials, the MCP logins, and the plugin manager for the bundled plugins `login`, `mcp`, and `plugins`.

import { underStop } from "yuke:internal/events";
import {
  authCancelLogin,
  authLogin,
  authLogout,
  authSetApiKey,
  authWaitForLogin,
  catalogList,
  mcpCancelLogin,
  mcpCompleteLogin,
  mcpLogin,
  mcpLogout,
  type ViewEvent as NativeViewEvent,
  pluginsAdd,
  pluginsApply,
  pluginsCheck,
  pluginsFind,
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
  AddPluginsParams,
  AddPluginsResult,
  CheckPluginsResult,
  FindPluginsParams,
  FindPluginsResult,
  ListPluginsResult,
  LockedPlugin,
  LoginOutcome,
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
  return {
    id,
    signal: ended.signal,
    async sendMessage(message) {
      live();
      return sessionInput([id, message.content, message.modelContent]);
    },
    async notifyModel(notification) {
      live();
      return sessionNotify([id, plugin, notification.display, notification.text]);
    },
    close,
    [Symbol.dispose]: close,
    cancelTurn() {
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
  } satisfies SessionHandle;
}

/** The sessions for the plugin `plugin`. Its signal ends each handle that it opened. */
export function sessionsOf(plugin: string, signal: AbortSignal): Sessions {
  return {
    // Each request is async, so an argument that the native refuses rejects the promise and throws at no call.
    create: async (settings, options) => await sessionsCreate([settings, options?.parent]),
    fork: async (id, options) => await sessionsFork([id, options?.through]),
    list: async (params) => await sessionsList(params ?? {}),
    get: async (id) => await sessionsGet(id),
    async rename(id, title) {
      await sessionsRename([id, title]);
    },
    async remove(id) {
      await sessionsRemove(id);
    },
    open: (id, options) => open(plugin, signal, id, options),
    events: async (id, page) => await sessionsEvents([id, page.before, page.limit]),
    async closeForAll(id) {
      await sessionClose(id);
    },
  } satisfies Sessions;
}

/** The catalog of the providers and their models. */
export const catalog: Catalog = {
  list: async (options) => await catalogList(options?.all === true),
} satisfies Catalog;

/** A device login that has started. The user opens the URL and enters the code. */
export interface LoginInProgress {
  readonly verificationUrl: string;
  readonly userCode: string;
  /** Wait for the end of the login, and give its outcome. A login that has ended gives its outcome too. */
  readonly waitForEnd: () => Promise<LoginOutcome>;
}

/** The credentials of the providers, for the bundled plugin `login`, as the requests `auth/login`, `auth/setApiKey`, and `auth/logout` do. */
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

/** A login of an MCP server that has started. The user opens the URL, and the browser goes to a listener of yuke. */
export interface McpLoginInProgress {
  /** The page where the user approves the login. */
  readonly url: string;
  /**
   * Finish the login with the address that the browser ended on, for a browser that cannot reach the listener. It
   * throws when the address is not the redirect of this login, and the login goes on to wait.
   */
  readonly complete: (redirectUrl: string) => void;
  /** Wait for the end of the login, and give its outcome. A login that has ended gives its outcome too. */
  readonly waitForEnd: () => Promise<LoginOutcome>;
}

/** The logins of the MCP servers of an open session, for the bundled plugin `mcp`, as `mcp/login` and `mcp/logout` do. */
export interface McpLogins {
  /**
   * Start the login of `server`, which is in the state `needsLogin`. A new login of the same server ends the login
   * before it as `cancelled`. `options.signal` cancels the login while it waits for the redirect.
   */
  readonly login: (
    sessionId: SessionId,
    server: string,
    options?: { readonly signal?: AbortSignal },
  ) => Promise<McpLoginInProgress>;
  /** Remove the stored login of the remote `server`. A login in progress of the server ends first. */
  readonly logout: (sessionId: SessionId, server: string) => Promise<void>;
}

/**
 * The plugin manager of the profile, for the bundled plugin `plugins`. It does the work of the requests `plugin/*`. No
 * call runs plugin code, and a new commit loads at the next reload. Git asks for no password.
 */
export interface PluginManager {
  /** The plugins of `config.json` with their state on disk and their load. It uses no network. */
  readonly list: () => Promise<ListPluginsResult>;
  /**
   * Install the locked commit of each Git plugin, and lock each new one at the commit of its ref. `options.signal`
   * stops the work.
   */
  readonly sync: (options?: { readonly signal?: AbortSignal }) => Promise<SyncPluginsResult>;
  /**
   * The new commit of each installed Git plugin of `target` whose ref moved, with the log of the move. Each new commit
   * is installed, and `plugins.lock` stays as it is until `apply`. `options.signal` stops the work.
   */
  readonly check: (target: PluginTarget, options?: { readonly signal?: AbortSignal }) => Promise<CheckPluginsResult>;
  /** Write the commit of each entry of `entries` into `plugins.lock`. Each plugin must be in the lock. */
  readonly apply: (entries: readonly LockedPlugin[]) => Promise<void>;
  /** The plugins of a Git repository: each folder with a `plugin.json`. `options.signal` stops the work. */
  readonly find: (params: FindPluginsParams, options?: { readonly signal?: AbortSignal }) => Promise<FindPluginsResult>;
  /**
   * Add plugins of a Git repository to `config.json` by their names, install them, and lock them at the commit of the
   * ref. The comments of `config.json` stay. `options.signal` stops the work.
   */
  readonly add: (params: AddPluginsParams, options?: { readonly signal?: AbortSignal }) => Promise<AddPluginsResult>;
  /** Remove the plugin `name` from `config.json` and `plugins.lock`. Its install stays on disk. */
  readonly remove: (name: string) => Promise<void>;
}

/** Call `cancel` when `signal` aborts, or at once when it aborted already. */
function cancelOnAbort(signal: AbortSignal | undefined, cancel: () => void): void {
  if (signal?.aborted) cancel();
  else signal?.addEventListener("abort", cancel, { once: true });
}

/** The credentials of the providers. */
export const auth: Auth = {
  async login(provider, options) {
    const signal = options?.signal;
    signal?.throwIfAborted();
    const started = await authLogin(provider);
    cancelOnAbort(signal, () => authCancelLogin(started.loginId));
    let end: Promise<LoginOutcome> | undefined;
    return {
      verificationUrl: started.verificationUrl,
      userCode: started.userCode,
      waitForEnd: () => {
        end ??= authWaitForLogin(started.loginId);
        return end;
      },
    };
  },
  setApiKey: (provider, apiKey) => authSetApiKey({ provider, apiKey }),
  logout: (provider) => authLogout(provider),
} satisfies Auth;

/** The logins of the MCP servers. */
export const mcp: McpLogins = {
  async login(sessionId, server, options) {
    const signal = options?.signal;
    signal?.throwIfAborted();
    const started = await mcpLogin([sessionId, server]);
    cancelOnAbort(signal, () => mcpCancelLogin(started.loginId));
    let end: Promise<LoginOutcome> | undefined;
    return {
      url: started.url,
      complete: (redirectUrl) => mcpCompleteLogin([started.loginId, redirectUrl]),
      waitForEnd: () => {
        // The ids of the logins of providers and of MCP servers come from one counter, so one wait serves both.
        end ??= authWaitForLogin(started.loginId);
        return end;
      },
    };
  },
  logout: (sessionId, server) => mcpLogout([sessionId, server]),
} satisfies McpLogins;

/** The plugin manager of the profile. */
export const plugins: PluginManager = {
  list: () => pluginsList(null),
  sync: (options) => underStop(options?.signal, () => pluginsSync(null)),
  check: (target, options) => underStop(options?.signal, () => pluginsCheck({ target })),
  async apply(entries) {
    await pluginsApply({ plugins: [...entries] });
  },
  find: (params, options) => underStop(options?.signal, () => pluginsFind(params)),
  add: (params, options) => underStop(options?.signal, () => pluginsAdd(params)),
  async remove(name) {
    await pluginsRemove({ name });
  },
} satisfies PluginManager;
