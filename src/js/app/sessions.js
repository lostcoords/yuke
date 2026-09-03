// yuke:sessions — the session feed the finder and the catalog read.
import { root } from "yuke:core";
import { client } from "yuke:client";

/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_usage: Wire.TokenUsage, pending_compaction: null }} FeedActivity */
/** @typedef {{ session: Wire.Session, activity: FeedActivity }} FeedItem */
/** @typedef {{ id: string, title: string, activity: FeedActivity, session: Wire.Session }} SessionRow */
/** @typedef {Extract<import("yuke:engine-native").EngineEvent, { type: "index" }>} NativeIndexEvent */
/** @typedef {{ method: string, params: any }} BroadcastEvent */
/** @typedef {{ onCatalogChanged?: () => void }} SessionsConfig */


// The catalog belongs to the chat, so the owner supplies what a catalog change should do.
/** @type {() => void} */
let onCatalogChanged = () => {};

const IDLE_ACTIVITY = /** @type {FeedActivity} */ ({
  state: { type: "idle" },
  queued: 0,
  context_usage: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 },
  pending_compaction: null,
});

// --- session feed -------------------------------------------------------------------------
// One engine, one feed. It keeps no parallel copy of the store: an index change makes it read
// `session.list` again, and the drain coalesces a burst of changes into one read.
export class SessionFeed {
  constructor() {
    /** @type {Map<string, FeedItem>} */
    this.items = new Map();
    this.loading = false;
    this.loaded = false;
  }

  /** @param {Wire.SessionListResult} listResult @returns {void} */
  seed(listResult) {
    touchFeed();
    this.items.clear();
    const items = listResult && listResult.items ? listResult.items : [];
    for (const it of items) if (it && it.session) this.items.set(it.session.id, it);
    this.loaded = true;
  }

  // Read the list again. A second call while one is in flight is dropped, so a burst costs one read.
  /** @returns {Promise<void>} */
  refresh() {
    if (this.loading) return Promise.resolve();
    this.loading = true;
    return client
      .sessionList()
      .then((r) => this.seed(r))
      .catch(() => {})
      .then(() => {
        this.loading = false;
        root.invalidate();
      });
  }

  /** @returns {void} */
  clear() {
    touchFeed();
    this.items.clear();
    this.loaded = false;
  }

  /** @returns {SessionRow[]} */
  rows() {
    /** @type {SessionRow[]} */
    const out = [];
    for (const it of this.items.values()) {
      out.push({
        id: it.session.id,
        title: sessionTitle(it.session),
        activity: it.activity,
        session: it.session,
      });
    }
    return out;
  }
}

const feed = new SessionFeed();

// The feed only changes on a read, so the rows are rebuilt on a change and not on every frame.
let feedsRev = 0;

/** @returns {void} */
function touchFeed() {
  feedsRev++;
}

/** @type {{ rev: number, session: Wire.Session | null }} */
let newestLocal = { rev: -1, session: null };

// The newest session that names a model, cached so a status draw costs no scan.
/** @returns {Wire.Session | null} */
export function newestLocalModelSession() {
  if (newestLocal.rev === feedsRev) return newestLocal.session;
  /** @type {Wire.Session | null} */
  let best = null;
  for (const it of feed.items.values()) {
    const s = it.session;
    if (!s || !s.model) continue;
    if (!best || (s.updated_at_ms || 0) > (best.updated_at_ms || 0)) best = s;
  }
  newestLocal = { rev: feedsRev, session: best };
  return best;
}

// The live entry for one session, or null. This keeps the feed inside this module.
/** @param {string} sessionId @returns {FeedItem | null} */
export function feedItem(sessionId) {
  return feed.items.get(sessionId) || null;
}

/** @returns {SessionFeed} */
export function feedOf() {
  return feed;
}


/** @param {SessionRow} row @returns {string} */
export function rowKey(row) {
  return row.id;
}

/** @param {SessionRow} row @returns {string} */
export function rowLabel(row) {
  return row.title;
}
/** @param {Wire.Session} s @returns {string} */
function sessionTitle(s) {
  const t = (s && s.title ? s.title : "").trim();
  return t !== "" ? t : "untitled";
}

// A one-cell activity mark: "●" working, "" idle.
/** @param {FeedActivity} activity @returns {string} */
export function activityMark(activity) {
  const type = activity && activity.state ? activity.state.type : "idle";
  return type === "idle" ? "" : "●";
}



// The feed registration. No view keeps the list on screen; the finder reads it on demand.
export const sessionsPlugin = {
  name: "sessions",
  /** @param {import("yuke:ext").Context} ctx @param {unknown} config @returns {void} */
  apply(ctx, config) {
    const cfg = /** @type {SessionsConfig} */ (config || {});
    if (cfg.onCatalogChanged) {
      const previous = onCatalogChanged;
      onCatalogChanged = cfg.onCatalogChanged;
      ctx.effect(() => () => {
        onCatalogChanged = previous;
      });
    }

    // The engine is in this process, so the list is available at once and needs no connect event.
    feed.refresh();

    // An index change makes the feed read the list again; `refresh` drops a call already in flight.
    ctx.on("index.changed", () => {
      feed.refresh();
    });
  },
};
