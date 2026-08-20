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

function request(method, params) {
  return native.request(method, params).then(
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

export function connect(options) {
  return native.connect(options).catch((reason) => {
    throw clientError(reason);
  });
}

export function disconnect() {
  native.disconnect();
}

export function connectionState() {
  return native.state();
}

export function sessionList(params = {}) {
  return request("session.list", {
    scope: { type: "all" },
    population: { type: "top_level" },
    view: "active_recent",
    ...params,
  });
}

// Track `id` as the one open session, dropping any prior one. It needs a resync before folding.
export function sessionOpen(id) {
  native.sessionOpen(id);
}

// Stop tracking the open session and free its replica.
export function sessionClose() {
  native.sessionClose();
}

// The open session's change counter, or -1 when none is open. Poll this; re-read the outline only
// when it moves. (Unused by the default UI, which reacts to the "session" event instead.)
export function sessionRev() {
  return native.sessionRev();
}

// Resync the open session, installing the ordered cut so broadcasts resume folding.
export function sessionResync() {
  return native.sessionResync().catch((reason) => {
    throw clientError(reason);
  });
}

// The transcript outline (message ids + roles + the draft, no body text), or null when none is open.
// The virtualized transcript keeps this as its row index and pulls text on demand with sessionText.
export function sessionOutline() {
  return JSON.parse(native.sessionOutline());
}

// The concatenated text of one message by id (committed or the streaming draft), "" when absent.
export function sessionText(id) {
  return native.sessionText(id);
}

// Send `text` as a user message into `id`. The daemon commits it and streams the reply as broadcasts
// the replica folds, so nothing is inserted optimistically. Result: { type:"started"|"queued", … }.
export function sessionSendInput(id, text) {
  return request("session.send_input", {
    session_id: id,
    input: { type: "content", content: [{ type: "text", text }] },
  });
}

// Interrupt the open session's active run; clearQueue also drops every queued input (a hard stop).
// Result: { canceled_run, cleared_inputs, cleared_compaction }.
export function sessionCancelRun(id, clearQueue = false) {
  return request("session.cancel_run", {
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  });
}

// Immediate subdirectories of `params.path` (the daemon's default root when omitted), one page.
// Result: { path, parent, entries:[{ name, path, is_git_repo }], next_cursor }; parent is null at
// the filesystem root and next_cursor is null on the final page.
export function workspaceBrowse(params = {}) {
  return request("workspace.browse", params);
}
