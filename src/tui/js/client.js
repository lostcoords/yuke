// yuke:client — a FAKE client over in-JS fixtures, with the surface the daemon client will have.
// The default shell folds its events without a daemon; a real transport replaces it later.
import { events, root } from "yuke:core";

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

// --- fixtures -----------------------------------------------------------------------------
const IDLE_ACTIVITY = { state: { type: "idle" }, queued: 0, context_usage: null, pending_compaction: null };
const WORKING_ACTIVITY = { state: { type: "working" }, queued: 0, context_usage: null, pending_compaction: null };
const NOW = Date.now();

const WORKSPACES = [{ id: "ws1", title: "yuke" }];

const SEED = [
  {
    id: "s1",
    title: "markdown demo",
    workspace_id: "ws1",
    model: "opus",
    updated_at_ms: NOW - 120000,
    messages: [
      { id: "m1", type: "user", text: "show me a list and some code" },
      { id: "m2", type: "assistant", text: "Here you go:\n\n- **one**\n- two\n\n```js\nconst x = 1;\n```" },
    ],
  },
  { id: "s2", title: "", workspace_id: "ws1", model: "sonnet", updated_at_ms: NOW - 300000, messages: [] },
];

const BROWSE = {
  path: "/repo",
  parent: null,
  entries: [
    { name: "src", path: "/repo/src", is_git_repo: false },
    { name: "README.md", path: "/repo/README.md", is_git_repo: false },
  ],
  next_cursor: null,
};

const REPLY = "This is a **streamed** reply with `code` and a final point.".split(" ");

// --- state --------------------------------------------------------------------------------
// `store` is the daemon-side truth per session; it survives a mount close and a disconnect.
// `mounted` holds the client replicas by "connKey|id". `streams` drives the tick pump.
const conns = new Map(); // key -> { key, name, state }
const store = new Map(); // id -> { rev, messages, draft, queue }
const mounted = new Set(); // "connKey|id"
const streams = []; // { connKey, sessionId, s, words, i }
let nextUid = 100;

function rkey(connKey, id) {
  return connKey + "|" + id;
}

function newId() {
  return "x" + nextUid++;
}

function summaryOf(id, s) {
  const fx = SEED.find((x) => x.id === id) || {};
  return {
    id,
    title: fx.title !== undefined ? fx.title : "",
    workspace_id: fx.workspace_id,
    model: fx.model,
    updated_at_ms: s ? s.updated_at_ms : fx.updated_at_ms,
  };
}

function ensureStore(id) {
  let s = store.get(id);
  if (!s) {
    const fx = SEED.find((x) => x.id === id);
    s = { rev: 0, messages: fx ? fx.messages.map((m) => ({ ...m })) : [], draft: null, queue: [], updated_at_ms: fx ? fx.updated_at_ms : NOW };
    store.set(id, s);
  }
  return s;
}

function mountedStore(connKey, id) {
  return mounted.has(rkey(connKey, id)) ? store.get(id) || null : null;
}

// Tell the sidebar this session's activity changed.
function setActivity(connKey, id, activity) {
  events.emit("index", { connKey, method: "session.activity_changed", params: { session_id: id, activity } });
}

// --- streaming ----------------------------------------------------------------------------
// The tick service grows each open draft one word per tick, then commits it. The daemon pushes real
// deltas the same way, so the shell folds them through the same "session" events.
function startStream(connKey, id, s) {
  s.draft = { id: newId(), type: "assistant", text: "" };
  s.rev++;
  s.updated_at_ms = Date.now();
  streams.push({ connKey, sessionId: id, s, words: REPLY.slice(), i: 0 });
  setActivity(connKey, id, WORKING_ACTIVITY);
}

export function _pumpStreams() {
  for (let k = streams.length - 1; k >= 0; k--) {
    const st = streams[k];
    const s = st.s;
    if (st.i < st.words.length) {
      s.draft.text += (st.i === 0 ? "" : " ") + st.words[st.i];
      st.i++;
      s.rev++;
      events.emit("session", { connKey: st.connKey, sessionId: st.sessionId, kind: "active", id: s.draft.id });
      continue;
    }
    s.messages.push(s.draft);
    s.draft = null;
    s.rev++;
    streams.splice(k, 1);
    if (s.queue.length) {
      s.queue.shift();
      startStream(st.connKey, st.sessionId, s);
    } else {
      setActivity(st.connKey, st.sessionId, IDLE_ACTIVITY);
    }
    events.emit("session", { connKey: st.connKey, sessionId: st.sessionId, kind: "reload" });
  }
  return streams.length > 0;
}

const streamService = {
  needsTick() {
    return streams.length ? { periodMs: 80 } : null;
  },
  tick() {
    _pumpStreams();
  },
};
root.addService(streamService);

// --- connection ---------------------------------------------------------------------------
export function connect(options) {
  const key = (options && options.connKey) || "local";
  conns.set(key, { key, name: key === "local" ? "local" : key, state: "ready" });
  events.emit("conn", { key, kind: "ready", workspaces: WORKSPACES });
  return Promise.resolve();
}

export function disconnect(connKey) {
  conns.delete(connKey);
  // Drop the client replicas and streams; the daemon-side store survives.
  for (const key of Array.from(mounted)) if (key.indexOf(connKey + "|") === 0) mounted.delete(key);
  for (let k = streams.length - 1; k >= 0; k--) if (streams[k].connKey === connKey) streams.splice(k, 1);
  events.emit("conn", { key: connKey, kind: "close" });
}

export function connectionState(connKey) {
  const c = conns.get(connKey);
  return c ? c.state : "disconnected";
}

export function connections() {
  return Array.from(conns.values());
}

export function devices() {
  return Promise.resolve([]); // local only; no remote roster
}

// --- sessions -----------------------------------------------------------------------------
export function sessionList(connKey, _params = {}) {
  return Promise.resolve({
    items: SEED.map((fx) => ({ session: summaryOf(fx.id, store.get(fx.id)), activity: IDLE_ACTIVITY })),
  });
}

export function sessionOpen(connKey, sessionId) {
  ensureStore(sessionId);
  mounted.add(rkey(connKey, sessionId));
}

export function sessionClose(connKey, sessionId) {
  mounted.delete(rkey(connKey, sessionId));
}

export function sessionRev(connKey, sessionId) {
  const s = mountedStore(connKey, sessionId);
  return s ? s.rev : -1;
}

export function sessionResync(connKey, sessionId) {
  return Promise.resolve();
}

// The outline: committed message descriptors plus the active draft, or null when not mounted.
export function sessionOutline(connKey, sessionId) {
  const s = mountedStore(connKey, sessionId);
  if (!s) return null;
  return {
    messages: s.messages.map((m) => ({ id: m.id, type: m.type })),
    active: s.draft ? { id: s.draft.id, type: "assistant" } : null,
  };
}

export function sessionText(connKey, sessionId, messageId) {
  const s = mountedStore(connKey, sessionId);
  if (!s) return "";
  if (s.draft && s.draft.id === messageId) return s.draft.text;
  const m = s.messages.find((x) => x.id === messageId);
  return m ? m.text : "";
}

export function sessionSendInput(connKey, id, text) {
  const s = mountedStore(connKey, id);
  if (!s) return Promise.reject(new ClientError("not_open"));
  const inputId = newId();
  s.messages.push({ id: newId(), type: "user", text });
  s.rev++;
  s.updated_at_ms = Date.now();
  let type;
  if (s.draft) {
    // A reply is already streaming, so queue this turn's reply behind it.
    s.queue.push(inputId);
    type = "queued";
  } else {
    startStream(connKey, id, s);
    type = "started";
  }
  events.emit("session", { connKey, sessionId: id, kind: "reload" });
  return Promise.resolve({ type, input_id: inputId });
}

export function sessionCancelRun(connKey, id, clearQueue = false) {
  const s = mountedStore(connKey, id);
  if (!s) return Promise.reject(new ClientError("not_open"));
  for (let k = streams.length - 1; k >= 0; k--) {
    if (streams[k].connKey === connKey && streams[k].sessionId === id) streams.splice(k, 1);
  }
  let canceled = null;
  if (s.draft) {
    canceled = s.draft.id;
    s.messages.push(s.draft);
    s.draft = null;
    s.rev++;
  }
  const clearedInputs = clearQueue ? s.queue.splice(0).length : 0;
  if (canceled) {
    setActivity(connKey, id, IDLE_ACTIVITY);
    events.emit("session", { connKey, sessionId: id, kind: "reload" });
  }
  return Promise.resolve({ canceled_run: canceled, cleared_inputs: clearedInputs, cleared_compaction: null });
}

// A stub browse: it returns one fixed listing. The explorer does not descend yet.
export function workspaceBrowse(connKey, params = {}) {
  return Promise.resolve({ ...BROWSE, path: params.path || BROWSE.path });
}
