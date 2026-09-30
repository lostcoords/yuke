// The in-process JavaScript seam over `yuke:internal/native/engine`.
import { native } from "yuke:internal/native/engine";
import { events } from "yuke:internal/kernel";
import { gateInput } from "yuke:internal/ext";

/** @import { MessagePart, PartRead, SessionOutline, TextCursor, ViewCut, ViewPart } from "yuke:internal/native/engine" */

// This module emits the drain per kind in every frontend, so it declares the names and a headless bus accepts them.
events.declare(["session.changed", "index.changed"]);

// The kernel owns the sink, so the view tier reads the digest from the bus like everything else.
events.on("engine.drained", (ev) => {
  if (ev.type === "session") events.emit("session.changed", ev);
  else events.emit("index.changed", ev);
});

/**
 * Send one engine request and answer its parsed result after the command and its hooks settle. An input passes the `input.before` hooks first.
 * @template {keyof Wire.Methods} M @param {M} method @param {Wire.Methods[M]["paramsType"]} args @returns {Promise<Wire.Methods[M]["returnType"]>}
 */
async function request(method, ...args) {
  const params = await gateInput(method, args[0] ?? /** @type {Wire.Methods[M]["paramsType"][0]} */ ({}));
  return JSON.parse(await native.request(method, JSON.stringify(params)));
}

/**
 * List one page of sessions. The default population is the top-level sessions.
 * @param {Wire.SessionListParams} [params] @returns {Promise<Wire.SessionListResult>}
 */
function sessionList(params = {}) {
  return request("session.list", {
    population: { type: "top_level" },
    ...params,
  });
}

// A complete child list costs at most 32 pages; a limit or cursor cycle is an error.
/** @param {string} parentId @returns {Promise<Wire.SessionListItem[]>} */
export async function allChildren(parentId) {
  /** @type {Wire.SessionListItem[]} */
  const items = [];
  const seen = new Set();
  /** @type {string | undefined} */
  let cursor;
  for (let n = 0; n < 32; n++) {
    const page = await client.sessionList({ population: { type: "children", parent_id: parentId }, limit: 100, ...(cursor ? { cursor } : {}) });
    items.push(...page.items);
    if (!page.next_cursor) return items;
    if (seen.has(page.next_cursor)) throw new Error("The child page cursor did not advance.");
    seen.add(page.next_cursor);
    cursor = page.next_cursor;
  }
  throw new Error("The child list exceeds 32 pages.");
}


/**
 * The transcript outline (message ids, roles, and the draft), or null when the session is not open.
 * @param {string} sessionId @returns {SessionOutline | null}
 */
function sessionOutline(sessionId) {
  return JSON.parse(native.sessionOutline(sessionId));
}

/**
 * The live activity of an open session, or null when no pane holds it.
 * @param {string} sessionId @returns {Wire.SessionActivity | null}
 */
function sessionActivity(sessionId) {
  return JSON.parse(native.sessionActivity(sessionId));
}

/**
 * One session with the activity the engine holds now, open or not.
 * @param {string} sessionId @returns {Promise<Wire.SessionListItem>}
 */
function sessionGet(sessionId) {
  return request("session.get", { session_id: sessionId });
}

/**
 * Read one session and check its files. `context_changes` says whether AGENTS.md or the skill roots differ from the stored snapshots.
 * @param {string} sessionId @returns {Promise<Wire.SessionListItem>}
 */
function sessionCheckContext(sessionId) {
  return request("session.get", { session_id: sessionId, check_files: true });
}

/**
 * Read one session with the facts that the context window shows: the instruction sources, the skills, and `usage_last`.
 * It never resolves to null. It throws when the engine does not know the session or the request fails.
 * @param {string} sessionId @returns {Promise<Wire.SessionListItem>}
 */
function sessionContextInfo(sessionId) {
  return request("session.get", { session_id: sessionId, last_usage: true });
}

/**
 * Rescan AGENTS.md and the skill roots for one idle session. The next run uses the new snapshots.
 * @param {string} sessionId @returns {Promise<Wire.SessionReloadContextResult>}
 */
function sessionReloadContext(sessionId) {
  return request("session.reload_context", { session_id: sessionId });
}

/**
 * Read the body of one skill from the session catalog. The engine reads the file now.
 * @param {string} sessionId @param {string} name @returns {Promise<Wire.SkillLoadResult>}
 */
function skillLoad(sessionId, name) {
  return request("skill.load", { session_id: sessionId, name });
}

/**
 * The queued inputs of a session, oldest first.
 * @param {string} sessionId @returns {Promise<Wire.SessionQueueResult>}
 */
function sessionQueue(sessionId) {
  return request("session.queue", { session_id: sessionId });
}

/**
 * Copy one image file into the engine blob store. The ref goes into an image content part.
 * @param {string} path @returns {Promise<Wire.MediaBlob>}
 */
function blobPut(path) {
  return request("blob.put", { path });
}

/**
 * Store image bytes a tool received in base64, such as an MCP image block. The engine names the type from the bytes.
 * @param {string} data @returns {Promise<Wire.MediaBlob>}
 */
function blobPutData(data) {
  return request("blob.put", { data });
}

/**
 * The parts of one message. The text of a text part and the arguments of a tool part are complete; a tool body and a view stay paged.
 * @param {string} sessionId @param {number} messageId @returns {MessagePart[]}
 */
function sessionParts(sessionId, messageId) {
  const parts = /** @type {ViewPart[]} */ (JSON.parse(native.sessionParts(sessionId, messageId)));
  return parts.map((p) => wholePart(sessionId, messageId, p));
}

/**
 * One part of a message, or null when it is gone. With the cursor of a held text, the read carries only the new text.
 * @param {string} sessionId @param {number} messageId @param {number} partId @param {TextCursor} [cursor] @returns {PartRead | null}
 */
function sessionPart(sessionId, messageId, partId, cursor) {
  const p = /** @type {ViewPart | undefined} */ (JSON.parse(native.sessionPart(sessionId, messageId, partId, cursor?.generation, cursor?.bytes))[0]);
  if (!p) return null;
  const next = p.text_generation === undefined || p.text_bytes === undefined ? null : { generation: p.text_generation, bytes: p.text_bytes };
  const tail = !!p.text_offset;
  return { part: wholePart(sessionId, messageId, p), cursor: next, tail };
}

/** @param {string} sessionId @param {number} messageId @param {ViewPart} p @returns {ViewPart} */
function wholePart(sessionId, messageId, p) {
  delete p.text_generation;
  delete p.text_bytes;
  delete p.text_offset;
  // Complete the text or tool arguments; the tool body and views stay paged.
  const field = p.type === "tool" ? "arguments" : "text";
  const cut = p.cut && p.cut.find((c) => c.field === field && c.next != null);
  if (!cut) return p;
  const tail = partTextFrom(sessionId, messageId, p.id, field, /** @type {number} */ (cut.next));
  const remaining = /** @type {readonly ViewCut[]} */ (p.cut).filter((c) => c !== cut);
  if (p.type === "tool") return { ...p, arguments: p.arguments + tail, cut: remaining };
  if (p.type === "text" || p.type === "reasoning") return { ...p, text: p.text + tail, cut: remaining };
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

/**
 * One page of one field of a part. `field` is the address that a `cut` entry names. `next` is the offset of the next page, or null at the end.
 * @param {string} sessionId @param {number} messageId @param {number} partId @param {string} field @param {number} [offset] @param {number} [limit] @returns {{ text: string, next: number | null }}
 */
function partTextPage(sessionId, messageId, partId, field, offset = 0, limit = 0) {
  return JSON.parse(native.partText(sessionId, messageId, partId, field, offset, limit));
}

/**
 * The content array for one text input, such as the `content` of `sessionSendInput`.
 * @param {string} text @returns {Wire.ContentPart[]}
 */
function textContent(text) {
  return [{ type: "text", text }];
}

/**
 * Send user content to a session. The engine starts a run, or queues the input while a run is active. The `input.before` hooks can change or block it.
 * @param {string} id @param {readonly Wire.ContentPart[]} content @param {Wire.ToolSite} [parentTool] - The tool call of a parent session that sends this input.
 * @returns {Promise<Wire.SessionSendInputResult>}
 */
function sessionSendInput(id, content, parentTool) {
  return request("session.send_input", { ...(parentTool ? { parent_tool: parentTool } : {}), session_id: id, input: { type: "content", content } });
}

/**
 * Send an explicit skill invocation. The engine loads the body and appends one user message with the arguments after it.
 * @param {string} id @param {string} name @param {string} [args] @returns {Promise<Wire.SessionSendInputResult>}
 */
function sessionSendSkill(id, name, args) {
  return request("session.send_input", { session_id: id, input: { type: "skill", name, ...(args ? { arguments: args } : {}) } });
}

/**
 * Stop the active run. The queue survives unless `clearQueue` asks otherwise, and the next queued input starts at once.
 * @param {string} id @param {boolean} [clearQueue] @returns {Promise<Wire.SessionCancelRunResult>}
 */
function sessionCancelRun(id, clearQueue = false) {
  return request("session.cancel_run", {
    session_id: id,
    ...(clearQueue ? { clear_queue: true } : {}),
  });
}

/**
 * Summarize the history below a boundary. A run in flight holds the compaction until it ends.
 * @param {string} id @returns {Promise<Wire.SessionCompactResult>}
 */
function sessionCompact(id) {
  return request("session.compact", { session_id: id });
}

/**
 * Drop one queued input. A started input belongs to the run, so the engine refuses it.
 * @param {string} id @param {number} inputId @returns {Promise<Wire.SessionCancelInputResult>}
 */
function sessionCancelInput(id, inputId) {
  return request("session.cancel_input", { session_id: id, input_id: inputId });
}

/**
 * Create a session. An unset reasoning takes the default of the model, and a session with no model is refused.
 * @param {Wire.CreateSession} params @returns {Promise<Wire.SessionResult>}
 */
function sessionCreate(params) {
  return request("session.create", params);
}

/**
 * Change the named settings of one session; an absent field keeps its current value.
 * @param {string} sessionId @param {Wire.SessionPatch} patch @returns {Promise<Wire.Session>}
 */
function sessionPatch(sessionId, patch) {
  return request("session.patch", { session_id: sessionId, patch });
}

/**
 * The provider and model catalog. An `unchanged` result means the caller keeps the models it holds.
 * @param {Wire.CatalogRev | null | undefined} sinceRev @returns {Promise<Wire.CatalogListResult>}
 */
function catalogList(sinceRev) {
  return request("catalog.list", sinceRev ? { since_rev: sinceRev } : {});
}

/**
 * Read providers.json again. `changed` reports whether the catalog revision moved.
 * @returns {Promise<Wire.CatalogReloadResult>}
 */
function catalogReload() {
  return request("catalog.reload", {});
}

/**
 * Start a device-code login. The engine polls in its own task and reports through `auth.login_finished`.
 * @param {string} providerId @returns {Promise<Wire.AuthLoginResult>}
 */
function authLogin(providerId) {
  return request("auth.login", { provider_id: providerId });
}

// Subscribe first because the owner drains engine events before it settles request promises.
/**
 * Start a device-code login and follow it. `start` answers the URL and the code, and `outcome` settles when the login ends.
 * `dispose` stops the follow, and `outcome` then never settles.
 * @param {string} providerId @returns {{ start: Promise<Wire.AuthLoginResult>, outcome: Promise<Wire.AuthLoginOutcome>, dispose: () => void }}
 */
function authLoginTracked(providerId) {
  /** @type {Wire.AuthLoginFinishedData[]} */
  const seen = [];
  /** @type {string | null} */
  let loginId = null;
  /** @type {(outcome: Wire.AuthLoginOutcome) => void} */
  let resolveOutcome = () => {};
  const outcome = /** @type {Promise<Wire.AuthLoginOutcome>} */ (new Promise((resolve) => { resolveOutcome = resolve; }));
  let active = true;
  /** @type {() => void} */
  let off = () => {};
  const dispose = () => {
    if (!active) return;
    active = false;
    off();
  };
  /** @param {Wire.AuthLoginOutcome} value */
  const finish = (value) => {
    if (!active) return;
    dispose();
    resolveOutcome(value);
  };
  off = events.on("auth.login_finished", (event) => {
    for (const note of event.auth || []) {
      if (loginId === note.params.login_id) finish(note.params.outcome);
      else if (loginId === null) seen.push(note.params);
    }
  });
  const start = client.authLogin(providerId).then((value) => {
    loginId = value.login_id;
    const prior = seen.find((event) => event.login_id === loginId);
    if (prior) finish(prior.outcome);
    return value;
  }, (error) => {
    dispose();
    throw error;
  });
  return { start, outcome, dispose };
}

/** Cancel a device-code login that `authLogin` started. @param {string} loginId @returns {Promise<Wire.Empty>} */
function authCancelLogin(loginId) {
  return request("auth.cancel_login", { login_id: loginId });
}

/**
 * Store one API key. The wire never returns it.
 * @param {string} providerId @param {string} apiKey @returns {Promise<Wire.Empty>}
 */
function authSetApiKey(providerId, apiKey) {
  return request("auth.set_api_key", { provider_id: providerId, api_key: apiKey });
}

/** Remove the credential that the engine holds for one provider. @param {string} providerId @returns {Promise<Wire.Empty>} */
function authRemove(providerId) {
  return request("auth.remove", { provider_id: providerId });
}

// One object carries the whole surface, so a test or a plugin can replace a single method.

/**
 * The in-process engine client: sessions, input, transcripts, the model catalog, and provider logins.
 * A request method rejects when the engine refuses the request.
 */
export const client = {
  /** The counts of process-owned runs and continuations. `engine.activity.changed` fires once for each change. */
  load: native.load,
  /** True while the process owns a run or a continuation. */
  isBusy: () => { const load = native.load(); return load.runs > 0 || load.continuations > 0; },
  request,
  sessionList,
  /** Pin the engine runtime of a session while a pane shows it. It answers false when the engine cannot open the session. Each open needs exactly one `sessionClose`, or the runtime never evicts. */
  sessionOpen: native.sessionOpen,
  sessionClose: native.sessionClose,
  /** The memory that the JavaScript runtime holds now. The process also holds memory on the Zig side. */
  memoryUsage: native.memoryUsage,
  sessionOutline,
  sessionActivity,
  sessionGet,
  sessionCheckContext,
  sessionContextInfo,
  sessionReloadContext,
  skillLoad,
  sessionQueue,
  blobPut,
  blobPutData,
  sessionParts,
  sessionPart,
  partTextPage,
  textContent,
  sessionSendInput,
  sessionSendSkill,
  sessionCancelRun,
  sessionCompact,
  sessionCancelInput,
  sessionCreate,
  sessionPatch,
  catalogList,
  catalogReload,
  authLogin,
  authLoginTracked,
  authCancelLogin,
  authSetApiKey,
  authRemove,
};
