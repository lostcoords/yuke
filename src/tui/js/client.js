// yuke:client — the typed client surface over the native `yuke:client-native` bridge. It wraps the
// natives with error types and JSON decode; the native module owns the transport and the replicas.
import { native } from "yuke:client-native";
import { events } from "yuke:core";

// The native emits connection events on the owner. Send them to the shared bus.
native.setEventSink((ev) => events.emit(ev.type, ev));

export class ClientError extends Error {
  constructor(code) {
    super(String(code));
    this.name = "ClientError";
    this.code = String(code);
  }
}

export class RpcError extends Error {
  constructor(code, message) {
    super(String(message));
    this.name = "RpcError";
    this.code = Number(code);
  }
}

function clientError(reason) {
  return reason instanceof ClientError ? reason : new ClientError(reason);
}

export function connect(options) {
  return native.connect(options).catch((reason) => {
    throw clientError(reason);
  });
}

export function disconnect(connKey) {
  native.disconnect(connKey);
}

export function connectionState(connKey) {
  return native.state(connKey);
}

export function connections() {
  return native.connections();
}

export function devices() {
  return native.devices().catch((reason) => {
    throw clientError(reason);
  });
}

// A JSON-RPC request. The native returns the response text; unwrap the result or throw an RpcError.
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

export function sessionList(connKey, params = {}) {
  return request(connKey, "session.list", {
    scope: { type: "all" },
    population: { type: "top_level" },
    view: "active_recent",
    ...params,
  });
}

// Mount a replica for (connKey, sessionId). Idempotent. It needs a resync before it folds.
export function sessionOpen(connKey, sessionId) {
  native.sessionOpen(connKey, sessionId);
}

export function sessionClose(connKey, sessionId) {
  native.sessionClose(connKey, sessionId);
}

// The change counter for that pair, or -1 when it is not mounted.
export function sessionRev(connKey, sessionId) {
  return native.sessionRev(connKey, sessionId);
}

// Install the ordered cut, so broadcasts fold again for that pair.
export function sessionResync(connKey, sessionId) {
  return native.sessionResync(connKey, sessionId).catch((reason) => {
    throw clientError(reason);
  });
}

// The transcript outline (message ids, roles, and the draft), or null when not mounted.
export function sessionOutline(connKey, sessionId) {
  return JSON.parse(native.sessionOutline(connKey, sessionId));
}

// The concatenated text of one message (committed or the draft), "" when absent.
export function sessionText(connKey, sessionId, messageId) {
  return native.sessionText(connKey, sessionId, messageId);
}

// The assistant parts of one message (committed or the draft), [] when absent.
export function sessionParts(connKey, sessionId, messageId) {
  return JSON.parse(native.sessionParts(connKey, sessionId, messageId));
}

// Send `text` into `id`. The daemon commits it and streams the reply as broadcasts the replica folds.
export function sessionSendInput(connKey, id, text) {
  return request(connKey, "session.send_input", {
    session_id: id,
    input: { type: "content", content: [{ type: "text", text }] },
  });
}

// Interrupt the open session's active run; clearQueue also drops every queued input.
export function sessionCancelRun(connKey, id, clearQueue = false) {
  return request(connKey, "session.cancel_run", {
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  });
}

// Create a session. An unset model or reasoning lets the daemon use its profile default.
export function sessionCreate(connKey, params) {
  return request(connKey, "session.create", params);
}

// The provider and model catalog. An `unchanged` result means the caller keeps the models it holds.
export function catalogList(connKey, sinceRev) {
  return request(connKey, "catalog.list", sinceRev ? { since_rev: sinceRev } : {});
}

// The subdirectories of `params.path` (the daemon's default root when omitted), one page.
export function workspaceBrowse(connKey, params = {}) {
  return request(connKey, "workspace.browse", params);
}
