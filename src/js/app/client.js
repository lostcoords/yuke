// yuke:client — the in-process JavaScript seam over `yuke:engine-native`.
import { native } from "yuke:engine-native";
import { events } from "yuke:core";
import { sendInput } from "yuke:ext";

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

// The native task answers JSON after the command and its hooks settle.
/** @template {keyof Wire.Methods} M @param {M} method @param {Wire.Methods[M]["paramsType"]} args @returns {Promise<Wire.Methods[M]["returnType"]>} */
async function request(method, ...args) {
  const text = await native.request(method, JSON.stringify(args[0] ?? {}));
  try {
    return JSON.parse(text);
  } catch {
    const error = new Error("malformed engine result");
    error.name = "EngineError";
    throw error;
  }
}

/** @param {Wire.SessionListParams} [params] @returns {Promise<Wire.SessionListResult>} */
function sessionList(params = {}) {
  return request("session.list", {
    population: { type: "top_level" },
    view: "active_recent",
    ...params,
  });
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


// What the JavaScript runtime holds right now. The process footprint also carries the Zig side.
/** @returns {import("yuke:engine-native").MemoryUsage} */
function memoryUsage() {
  return native.memoryUsage();
}

// The transcript outline (message ids, roles, and the draft), or null when the session is not open.
/** @param {string} sessionId @returns {import("yuke:engine-native").SessionOutline | null} */
function sessionOutline(sessionId) {
  return JSON.parse(native.sessionOutline(sessionId));
}

// The live activity of an open session, or null when no pane holds it.
/** @param {string} sessionId @returns {Wire.SessionActivity | null} */
function sessionActivity(sessionId) {
  return JSON.parse(native.sessionActivity(sessionId));
}

// One session with the activity the engine holds now, open or not.
/** @param {string} sessionId @returns {Promise<Wire.SessionListItem>} */
function sessionGet(sessionId) {
  return request("session.get", { session_id: sessionId });
}

// The queued inputs of a session, oldest first.
/** @param {string} sessionId @returns {Promise<Wire.SessionQueueResult>} */
function sessionQueue(sessionId) {
  return request("session.queue", { session_id: sessionId });
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
  return parts.map((p) => wholePart(sessionId, messageId, p));
}

// One part of a message, or null when it is gone. A delta re-reads one part, never the whole message.
/** @param {string} sessionId @param {number} messageId @param {number} partId @returns {Wire.AssistantPart | null} */
function sessionPart(sessionId, messageId, partId) {
  const parts = /** @type {ViewPart[]} */ (JSON.parse(native.sessionPart(sessionId, messageId, partId)));
  return parts.length ? wholePart(sessionId, messageId, /** @type {ViewPart} */ (parts[0])) : null;
}

/** @param {string} sessionId @param {number} messageId @param {ViewPart} p @returns {ViewPart} */
function wholePart(sessionId, messageId, p) {
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

// Input goes through the gate in `yuke:ext`, so a plugin reads it before the engine does.
/** @param {string} id @param {string} text @returns {Promise<Wire.SessionSendInputResult>} */
function sessionSendInput(id, text) {
  return sendInput({ session_id: id, input: { type: "content", content: [{ type: "text", text }] } });
}

// Stop the active run. The queue survives unless `clearQueue` asks otherwise, and the next queued input starts at once.
/** @param {string} id @param {boolean} [clearQueue] @returns {Promise<Wire.SessionCancelRunResult>} */
function sessionCancelRun(id, clearQueue = false) {
  return request("session.cancel_run", {
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  });
}

// Drop one queued input. A started input belongs to the run, so the engine refuses it.
/** @param {string} id @param {number} inputId @returns {Promise<Wire.SessionCancelInputResult>} */
function sessionCancelInput(id, inputId) {
  return request("session.cancel_input", { session_id: id, input_id: inputId });
}

// Create a session. An unset model or reasoning lets the engine use its profile default.
/** @param {Wire.CreateSession} params @returns {Promise<Wire.SessionResult>} */
function sessionCreate(params) {
  return request("session.create", params);
}

// The provider and model catalog. An `unchanged` result means the caller keeps the models it holds.
/** @param {Wire.CatalogRev | null | undefined} sinceRev @returns {Promise<Wire.CatalogListResult>} */
function catalogList(sinceRev) {
  return request("catalog.list", sinceRev ? { since_rev: sinceRev } : {});
}

// Read providers.json again. `changed` reports whether the catalog revision moved.
/** @returns {Promise<Wire.CatalogReloadResult>} */
function catalogReload() {
  return request("catalog.reload", {});
}

/** @returns {Promise<Wire.AuthListResult>} */
function authList() {
  return request("auth.list", {});
}

// Start a device-code login. The engine polls in its own task and reports through `auth.login_finished`.
/** @param {string} providerId @returns {Promise<Wire.AuthLoginResult>} */
function authLogin(providerId) {
  return request("auth.login", { provider_id: providerId });
}

/** @param {string} loginId @returns {Promise<Wire.Empty>} */
function authCancelLogin(loginId) {
  return request("auth.cancel_login", { login_id: loginId });
}

// Store one API key. The wire never returns it.
/** @param {string} providerId @param {string} apiKey @returns {Promise<Wire.Empty>} */
function authSetApiKey(providerId, apiKey) {
  return request("auth.set_api_key", { provider_id: providerId, api_key: apiKey });
}

/** @param {string} providerId @returns {Promise<Wire.Empty>} */
function authRemove(providerId) {
  return request("auth.remove", { provider_id: providerId });
}

// One object carries the whole surface, so a test or a plugin can replace a single method.
export const client = {
  request,
  sessionList,
  sessionOpen,
  sessionClose,
  memoryUsage,
  sessionOutline,
  sessionActivity,
  sessionGet,
  sessionQueue,
  sessionText,
  sessionTextPage,
  sessionParts,
  sessionPart,
  partTextPage,
  sessionSendInput,
  sessionCancelRun,
  sessionCancelInput,
  sessionCreate,
  catalogList,
  catalogReload,
  authList,
  authLogin,
  authCancelLogin,
  authSetApiKey,
  authRemove,
};
