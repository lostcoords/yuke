// yuke:client — the in-process JavaScript seam over `yuke:engine-native`.
import { native } from "yuke:engine-native";
import { events } from "yuke:core";

// This table maps a native event type to its core event name.
/** @type {Record<string, string>} */
const ENGINE_TO_CORE_EVENT = { session: "session.changed", index: "index.changed" };

// The native drains engine events on the owner. Send them to the shared bus.
native.setEventSink((ev) => {
  const name = ENGINE_TO_CORE_EVENT[ev.type];
  if (name) events.emit(name, ev);
});

// One request against the engine. The call is synchronous, but the surface stays a Promise so a
// caller does not change when a command later moves off the owner.
// Every caller casts its parameters to the generated wire type, so a wrong shape fails `tsc`
// instead of reaching the engine and refusing at run time.
/** @param {string} method @param {Wire.RequestParams} params @returns {Promise<any>} */
function request(method, params) {
  let text;
  try {
    text = native.request(method, JSON.stringify(params));
  } catch (reason) {
    return Promise.reject(reason);
  }
  try {
    return Promise.resolve(JSON.parse(text));
  } catch {
    const error = new Error("malformed engine result");
    error.name = "EngineError";
    return Promise.reject(error);
  }
}

/** @param {Wire.SessionListParams} [params] @returns {Promise<Wire.SessionListResult>} */
function sessionList(params = {}) {
  return request("session.list", /** @type {Wire.SessionListParams} */ ({
    population: { type: "top_level" },
    view: "active_recent",
    ...params,
  }));
}

// Open a view onto a session. The pin holds the engine runtime while a pane shows it.
/** @param {string} sessionId @returns {boolean} */
function sessionOpen(sessionId) {
  return native.sessionOpen(sessionId);
}

// Close one view. Every open must have exactly one close, or the runtime never evicts.
/** @param {string} sessionId @returns {void} */
function sessionClose(sessionId) {
  native.sessionClose(sessionId);
}


// The transcript outline (message ids, roles, and the draft), or null when the session is not open.
/** @param {string} sessionId @returns {import("yuke:engine-native").SessionOutline | null} */
function sessionOutline(sessionId) {
  return JSON.parse(native.sessionOutline(sessionId));
}

// One page of a message's whole text. `next` is the offset to ask for, or null at the end.
/**
 * @param {string} sessionId @param {number} messageId
 * @param {number} [offset] @param {number} [limit]
 * @returns {{ text: string, next: number | null, bytes: number }}
 */
function sessionTextPage(sessionId, messageId, offset = 0, limit = 0) {
  return JSON.parse(native.sessionText(sessionId, messageId, offset, limit));
}

// The concatenated text of one message, up to `max` bytes. A longer message is cut on a character.
/** @param {string} sessionId @param {number} messageId @param {number} [max] @returns {string} */
function sessionText(sessionId, messageId, max = 0) {
  return sessionTextPage(sessionId, messageId, 0, max).text;
}

// The assistant parts of one message. A part carries bounded text plus its real `bytes`.
/** @param {string} sessionId @param {number} messageId @returns {Wire.AssistantPart[]} */
function sessionParts(sessionId, messageId) {
  return JSON.parse(native.sessionParts(sessionId, messageId));
}

// One page of a single part's text, for a part whose inline text was cut.
/**
 * @param {string} sessionId @param {number} messageId @param {number} partId
 * @param {number} [offset] @param {number} [limit]
 * @returns {{ text: string, next: number | null }}
 */
function partTextPage(sessionId, messageId, partId, offset = 0, limit = 0) {
  return JSON.parse(native.partText(sessionId, messageId, partId, offset, limit));
}

/** @param {string} id @param {string} text @returns {Promise<Wire.SessionSendInputResult>} */
function sessionSendInput(id, text) {
  return request("session.send_input", /** @type {Wire.SessionSendInputParams} */ ({
    session_id: id,
    input: { type: "content", content: [{ type: "text", text }] },
  }));
}

/** @param {string} id @param {boolean} [clearQueue] @returns {Promise<Wire.SessionCancelRunResult>} */
function sessionCancelRun(id, clearQueue = false) {
  return request("session.cancel_run", /** @type {Wire.SessionCancelRunParams} */ ({
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  }));
}

// Create a session. An unset model or reasoning lets the engine use its profile default.
/** @param {Wire.CreateSession} params @returns {Promise<Wire.SessionResult>} */
function sessionCreate(params) {
  return request("session.create", params);
}

// The provider and model catalog. An `unchanged` result means the caller keeps the models it holds.
/** @param {Wire.CatalogRev | null | undefined} sinceRev @returns {Promise<Wire.CatalogListResult>} */
function catalogList(sinceRev) {
  return request("catalog.list", /** @type {Wire.CatalogListParams} */ (sinceRev ? { since_rev: sinceRev } : {}));
}

// One object carries the whole surface, so a test or a plugin can replace a single method.
export const client = {
  request,
  sessionList,
  sessionOpen,
  sessionClose,
  sessionOutline,
  sessionText,
  sessionTextPage,
  sessionParts,
  partTextPage,
  sessionSendInput,
  sessionCancelRun,
  sessionCreate,
  catalogList,
};
