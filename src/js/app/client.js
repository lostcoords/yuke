// yuke:client — the in-process JavaScript seam over `yuke:engine-native`.
import { native } from "yuke:engine-native";
import { events } from "yuke:core";

/** @typedef {import("yuke:engine-native").ViewPart} ViewPart */
/** @typedef {import("yuke:engine-native").ViewCut} ViewCut */

// This table maps a native event type to its core event name.
/** @type {Record<string, string>} */
const ENGINE_TO_CORE_EVENT = { session: "session.changed", index: "index.changed" };

// The kernel owns the sink, so the view tier reads the digest from the bus like everything else.
events.on("engine.drained", (ev) => {
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

// The assistant parts of one message. A cut field every row reads is completed here, and a large body stays paged.
/** @param {string} sessionId @param {number} messageId @returns {Wire.AssistantPart[]} */
function sessionParts(sessionId, messageId) {
  const parts = /** @type {ViewPart[]} */ (JSON.parse(native.sessionParts(sessionId, messageId)));
  return parts.map((p) => {
    if (!p || !p.cut) return p;
    // The part already carries the prefix, so a tail resumes at `next` and nothing is read twice.
    if (p.type === "text" || p.type === "reasoning") {
      const cut = p.cut.find((c) => c.field === "text" && c.next != null);
      if (!cut) return p;
      const tail = partTextFrom(sessionId, messageId, p.id, "text", /** @type {number} */ (cut.next));
      return { ...p, text: p.text + tail, cut: p.cut.filter((c) => c !== cut) };
    }
    // A row parses the arguments for its header, so a cut one must be whole. The body views stay paged.
    if (p.type === "tool") {
      const cut = p.cut.find((c) => c.field === "arguments" && c.next != null);
      if (!cut) return p;
      const tail = partTextFrom(sessionId, messageId, p.id, "arguments", /** @type {number} */ (cut.next));
      return { ...p, arguments: p.arguments + tail, cut: p.cut.filter((c) => c !== cut) };
    }
    return p;
  });
}

// The rest of one field from `offset`. Each page echoes the next byte offset back, so no caller counts bytes of its own.
/** @param {string} sessionId @param {number} messageId @param {number} partId @param {string} field @param {number} offset @returns {string} */
function partTextFrom(sessionId, messageId, partId, field, offset) {
  let text = "";
  /** @type {number | null} */
  let at = offset;
  while (at != null) {
    const page = partTextPage(sessionId, messageId, partId, field, at, 0);
    text += page.text;
    at = page.next;
  }
  return text;
}

// One page of one field of a part. `field` is the address a `cut` entry names, passed back unchanged.
/**
 * @param {string} sessionId @param {number} messageId @param {number} partId @param {string} field
 * @param {number} [offset] @param {number} [limit]
 * @returns {{ text: string, next: number | null }}
 */
function partTextPage(sessionId, messageId, partId, field, offset = 0, limit = 0) {
  return JSON.parse(native.partText(sessionId, messageId, partId, field, offset, limit));
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
