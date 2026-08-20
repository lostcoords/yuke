// yuke:client — typed client script surface over the private native wire bridge.
import { native } from "yuke:client-native";

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

function request(connKey, method, params) {
  return native.request(connKey, method, params).then(
    (text) => {
      const response = JSON.parse(text);
      if (response.error) {
        throw new RpcError(response.error.code, response.error.message);
      }

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

// Mount a replica for `(connKey, sessionId)`. Idempotent if already open. Needs a resync before folding.
export function sessionOpen(connKey, sessionId) {
  native.sessionOpen(connKey, sessionId);
}

// Drop the replica for `(connKey, sessionId)`.
export function sessionClose(connKey, sessionId) {
  native.sessionClose(connKey, sessionId);
}

// Change counter for that pair, or -1 when it is not mounted.
export function sessionRev(connKey, sessionId) {
  return native.sessionRev(connKey, sessionId);
}

// Install the ordered cut so broadcasts resume folding for that pair.
export function sessionResync(connKey, sessionId) {
  return native.sessionResync(connKey, sessionId).catch((reason) => {
    throw clientError(reason);
  });
}

// The transcript outline (message ids + roles + the draft, no body text), or null when not mounted.
export function sessionOutline(connKey, sessionId) {
  return JSON.parse(native.sessionOutline(connKey, sessionId));
}

// Concatenated text of one message (committed or the streaming draft), "" when absent.
export function sessionText(connKey, sessionId, messageId) {
  return native.sessionText(connKey, sessionId, messageId);
}

// Send `text` as a user message into `id`. The daemon commits it and streams the reply as broadcasts
// the replica folds, so nothing is inserted optimistically. Result: { type:"started"|"queued", … }.
export function sessionSendInput(connKey, id, text) {
  return request(connKey, "session.send_input", {
    session_id: id,
    input: { type: "content", content: [{ type: "text", text }] },
  });
}

// Interrupt the open session's active run; clearQueue also drops every queued input (a hard stop).
// Result: { canceled_run, cleared_inputs, cleared_compaction }.
export function sessionCancelRun(connKey, id, clearQueue = false) {
  return request(connKey, "session.cancel_run", {
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  });
}

// Immediate subdirectories of `params.path` (the daemon's default root when omitted), one page.
// Result: { path, parent, entries:[{ name, path, is_git_repo }], next_cursor }; parent is null at
// the filesystem root and next_cursor is null on the final page.
export function workspaceBrowse(connKey, params = {}) {
  return request(connKey, "workspace.browse", params);
}
