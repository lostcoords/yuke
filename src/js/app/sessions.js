// The session feed the finder and the catalog read.
import { Refresh } from "yuke:internal/refresh";
import { root } from "yuke:internal/core";
import { client } from "yuke:internal/client";

/** @import { Context } from "yuke:internal/ext" */
/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_usage: Wire.TokenUsage, pending_compaction: null }} FeedActivity */
/** @typedef {{ session: Wire.Session, activity: FeedActivity }} FeedItem */
/** @typedef {{ id: string, title: string, activity: FeedActivity, session: Wire.Session }} SessionRow */

// One engine, one feed. The feed keeps no copy of the store, so an index change makes it read `session.list` again.
class SessionFeed {
  #refresh;
  constructor() {
    /** @type {Map<string, FeedItem>} */
    this.items = new Map();
    this.#refresh = new Refresh(
      () => client.sessionList().then((r) => this.seed(r)),
      () => root.invalidate(),
    );
  }

  get loading() {
    return this.#refresh.loading;
  }

  /** @param {Wire.SessionListResult} listResult @returns {void} */
  seed(listResult) {
    feedsRev++;
    this.items.clear();
    for (const it of listResult.items) this.items.set(it.session.id, it);
  }

  // Read the list again. A burst shares one read and one follow-up catches changes during it.
  /** @returns {Promise<void>} */
  refresh() {
    return this.#refresh.run();
  }

  /** @returns {void} */
  clear() {
    feedsRev++;
    this.items.clear();
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
    if (!s.model) continue;
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

/** @param {Wire.Session} s @returns {string} */
function sessionTitle(s) {
  const t = s.title.trim();
  return t !== "" ? t : "untitled";
}

// A one-cell activity mark: "●" working, "" idle.
/** @param {FeedActivity} activity @returns {string} */
export function activityMark(activity) {
  const type = activity.state.type;
  return type === "idle" ? "" : "●";
}



// The feed registration. No view keeps the list on screen; the finder reads it on demand.
export const sessionsPlugin = {
  name: "sessions",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    // The engine is in this process, so the list is available at once and needs no connect event.
    feed.refresh();

    // An index change requests a fresh read, even if a previous read has not settled.
    ctx.on("index.changed", () => {
      feed.refresh();
    });
  },
};
