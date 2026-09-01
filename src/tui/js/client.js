// yuke:client — error types and JSON decode over `yuke:client-native`, which owns the transport and the replicas.
import { native } from "yuke:client-native";
import { events } from "yuke:core";

// This table maps a native client event type to its core event name.
const CLIENT_TO_CORE_EVENT = { session: "session.changed", index: "index.changed", conn: "conn.changed" };

// The native emits connection events on the owner. Send them to the shared bus.
native.setEventSink((ev) => {
  const name = CLIENT_TO_CORE_EVENT[ev.type];
  if (name) events.emit(name, ev);
});

export class ClientError extends Error {
  /** @param {unknown} code */
  constructor(code) {
    super(String(code));
    this.name = "ClientError";
    this.code = String(code);
  }
}

export class RpcError extends Error {
  /** @param {unknown} code @param {unknown} message */
  constructor(code, message) {
    super(String(message));
    this.name = "RpcError";
    this.code = Number(code);
  }
}

/** @param {unknown} reason @returns {ClientError} */
function clientError(reason) {
  return reason instanceof ClientError ? reason : new ClientError(reason);
}

// The key of the connection to the daemon on this machine.
const LOCAL = "local";

/** @param {Parameters<typeof native.connect>[0]} options @returns {ReturnType<typeof native.connect>} */
function connect(options) {
  return native.connect(options).catch((reason) => {
    throw clientError(reason);
  });
}

/** @param {string} connKey @returns {void} */
function disconnect(connKey) {
  native.disconnect(connKey);
}

/** @param {string} connKey @returns {import("yuke:client-native").ConnState} */
function connectionState(connKey) {
  return native.state(connKey);
}

/** @returns {ReturnType<typeof native.connections>} */
function connections() {
  return native.connections();
}

/** @returns {ReturnType<typeof native.devices>} */
function devices() {
  return native.devices().catch((reason) => {
    throw clientError(reason);
  });
}

// A JSON-RPC request. The native returns the response text; unwrap the result or throw an RpcError.
/**
 * @param {string} connKey
 * @param {string} method
 * @param {unknown} params
 * @returns {Promise<any>}
 */
function request(connKey, method, params) {
  return native.request(connKey, method, JSON.stringify(params)).then(
    (text) => {
      let response;
      try {
        response = JSON.parse(text);
      } catch (e) {
        throw new RpcError(-1, "malformed response");
      }
      if (typeof response !== "object" || response === null || Array.isArray(response)) {
        throw new RpcError(-1, "malformed response");
      }
      if (response.error) throw new RpcError(response.error.code, response.error.message);
      if (!("result" in response)) throw new RpcError(-1, "malformed response");
      return response.result;
    },
    (reason) => {
      throw clientError(reason);
    },
  );
}

/**
 * @param {string} connKey
 * @param {Wire.SessionListParams} [params]
 * @returns {Promise<Wire.SessionListResult>}
 */
function sessionList(connKey, params = {}) {
  return request(connKey, "session.list", {
    scope: { type: "all" },
    population: { type: "top_level" },
    view: "active_recent",
    ...params,
  });
}

// Mount a replica for (connKey, sessionId). Idempotent. It needs a resync before it folds.
/** @param {string} connKey @param {string} sessionId @returns {void} */
function sessionOpen(connKey, sessionId) {
  native.sessionOpen(connKey, sessionId);
}

/** @param {string} connKey @param {string} sessionId @returns {void} */
function sessionClose(connKey, sessionId) {
  native.sessionClose(connKey, sessionId);
}

// The change counter for that pair, or -1 when it is not mounted.
/** @param {string} connKey @param {string} sessionId @returns {number} */
function sessionRev(connKey, sessionId) {
  return native.sessionRev(connKey, sessionId);
}

// Install the ordered cut, so broadcasts fold again for that pair.
/** @param {string} connKey @param {string} sessionId @returns {Promise<void>} */
function sessionResync(connKey, sessionId) {
  return native.sessionResync(connKey, sessionId).catch((reason) => {
    throw clientError(reason);
  });
}

// The transcript outline (message ids, roles, and the draft), or null when not mounted.
/**
 * @param {string} connKey
 * @param {string} sessionId
 * @returns {import("yuke:client-native").SessionOutline}
 */
function sessionOutline(connKey, sessionId) {
  return JSON.parse(native.sessionOutline(connKey, sessionId));
}

// The concatenated text of one message (committed or the draft), "" when absent.
/** @param {string} connKey @param {string} sessionId @param {number} messageId @returns {string} */
function sessionText(connKey, sessionId, messageId) {
  return native.sessionText(connKey, sessionId, messageId);
}

// The assistant parts of one message (committed or the draft), [] when absent.
/**
 * @param {string} connKey
 * @param {string} sessionId
 * @param {number} messageId
 * @returns {Wire.AssistantPart[]}
 */
function sessionParts(connKey, sessionId, messageId) {
  return JSON.parse(native.sessionParts(connKey, sessionId, messageId));
}

// Send `text` into `id`. The daemon commits it and streams the reply as broadcasts the replica folds.
/**
 * @param {string} connKey
 * @param {string} id
 * @param {string} text
 * @returns {Promise<Wire.SessionSendInputResult>}
 */
function sessionSendInput(connKey, id, text) {
  return request(connKey, "session.send_input", {
    session_id: id,
    input: { type: "content", content: [{ type: "text", text }] },
  });
}

// Interrupt the open session's active run; clearQueue also drops every queued input.
/**
 * @param {string} connKey
 * @param {string} id
 * @param {boolean} [clearQueue]
 * @returns {Promise<Wire.SessionCancelRunResult>}
 */
function sessionCancelRun(connKey, id, clearQueue = false) {
  return request(connKey, "session.cancel_run", {
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  });
}

// Create a session. An unset model or reasoning lets the daemon use its profile default.
/**
 * @param {string} connKey
 * @param {Wire.CreateSession} params
 * @returns {Promise<Wire.SessionResult>}
 */
function sessionCreate(connKey, params) {
  return request(connKey, "session.create", params);
}

// The provider and model catalog. An `unchanged` result means the caller keeps the models it holds.
/**
 * @param {string} connKey
 * @param {Wire.CatalogRev | null | undefined} sinceRev
 * @returns {Promise<Wire.CatalogListResult>}
 */
function catalogList(connKey, sinceRev) {
  return request(connKey, "catalog.list", sinceRev ? { since_rev: sinceRev } : {});
}

// The subdirectories of `params.path` (the daemon's default root when omitted), one page.
/**
 * @param {string} connKey
 * @param {Wire.FsBrowseParams} [params]
 * @returns {Promise<Wire.FsBrowseResult>}
 */
function fsBrowse(connKey, params = {}) {
  return request(connKey, "fs.browse", params);
}

// One object carries the whole surface, so a test or a plugin can replace a single method.
export const client = {
  LOCAL,
  connect,
  disconnect,
  connectionState,
  connections,
  devices,
  sessionList,
  sessionOpen,
  sessionClose,
  sessionRev,
  sessionResync,
  sessionOutline,
  sessionText,
  sessionParts,
  sessionSendInput,
  sessionCancelRun,
  sessionCreate,
  catalogList,
  fsBrowse,
};
