// yuke:sidebar — the session list beside the chat, with one DeviceFeed per connection.
import { text, clip, root, strokeOf } from "yuke:core";
import { List } from "yuke:ui";
import * as client from "yuke:client";

/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_usage: Wire.TokenUsage, pending_compaction: null }} FeedActivity */
/** @typedef {{ session: Wire.Session, activity: FeedActivity }} FeedItem */
/** @typedef {{ connKey: string, id: string, title: string, activity: FeedActivity, session: Wire.Session, workspace: Wire.Workspace | null, deviceName: string }} SessionRow */
/** @typedef {{ connKey: string, sessionId: string }} OpenSession */
/** @typedef {{ onOpen?: (connKey: string, id: string, src: string) => void, statusLabel?: () => string, activeSession?: () => OpenSession | null }} SessionListOptions */
/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "index" }>} NativeIndexEvent */
/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "conn" }> & { workspaces?: readonly Wire.Workspace[] }} NativeConnEvent */
/** @typedef {{ method: string, params: any }} BroadcastEvent */
/** @typedef {{ deviceName?: (connKey: string) => string, onCatalogChanged?: (connKey: string) => void }} SidebarConfig */

const LOCAL = client.LOCAL;

// The catalog belongs to the chat, so the owner supplies what a catalog change should do.
/** @type {(connKey: string) => void} */
let onCatalogChanged = () => {};

const IDLE_ACTIVITY = /** @type {FeedActivity} */ ({
  state: { type: "idle" },
  queued: 0,
  context_usage: { input: 0, output: 0, reasoning: 0, cache_read: 0, cache_write: 0 },
  pending_compaction: null,
});

// --- device feed --------------------------------------------------------------------------
// A per-connection inbox. It folds ungated index events; it is not a replica.
export class DeviceFeed {
  /** @param {string} connKey */
  constructor(connKey) {
    this.connKey = connKey;
    this.name = connKey === LOCAL ? "local" : "";
    /** @type {Map<string, FeedItem>} */
    this.items = new Map();
    /** @type {Map<string, Wire.Workspace>} */
    this.workspaces = new Map();
    /** @type {BroadcastEvent[]} */
    this.pending = [];
    this.loaded = false;
  }

  /** @param {readonly Wire.Workspace[] | null | undefined} list */
  learnWorkspaces(list) {
    if (!list) return;
    touchFeeds();
    for (const ws of list) if (ws && ws.id) this.workspaces.set(ws.id, ws);
  }

  /** @param {Wire.SessionListResult} listResult */
  seed(listResult) {
    touchFeeds();
    this.items.clear();
    const items = listResult && listResult.items ? listResult.items : [];
    for (const it of items) if (it && it.session) this.items.set(it.session.id, it);
    this.loaded = true;
    const pending = this.pending;
    this.pending = [];
    for (const ev of pending) this._apply(ev);
  }

  /** @param {BroadcastEvent} ev */
  fold(ev) {
    touchFeeds();
    if (!this.loaded) {
      this.pending.push(ev);
      return;
    }
    this._apply(ev);
  }

  /** @param {BroadcastEvent} ev */
  _apply(ev) {
    const p = ev && ev.params ? ev.params : {};
    switch (ev && ev.method) {
      case "session.summary_changed":
        this._upsert(p.session);
        break;
      case "catalog.changed":
        onCatalogChanged(this.connKey);
        break;
      case "session.activity_changed": {
        const activity = p;
        const existing = this.items.get(activity.session_id);
        if (existing) this.items.set(activity.session_id, { session: existing.session, activity: activity.activity });
        break;
      }
      case "session.removed":
        this.items.delete(p.session_id);
        break;
      case "workspace.created":
        if (p.workspace && p.workspace.id) this.workspaces.set(p.workspace.id, p.workspace);
        break;
      case "workspace.removed":
        this.workspaces.delete(p.workspace_id);
        break;
    }
  }

  /** @param {Wire.Session} session */
  _upsert(session) {
    if (!session || !session.id) return;
    const existing = this.items.get(session.id);
    this.items.set(session.id, { session, activity: existing ? existing.activity : IDLE_ACTIVITY });
  }

  clear() {
    touchFeeds();
    this.items.clear();
    this.workspaces.clear();
    this.pending = [];
    this.loaded = false;
  }

  /** @returns {SessionRow[]} */
  rows() {
    /** @type {SessionRow[]} */
    const out = [];
    for (const it of this.items.values()) {
      out.push({
        connKey: this.connKey,
        id: it.session.id,
        title: sessionTitle(it.session),
        activity: it.activity,
        session: it.session,
        workspace: this.workspaces.get(it.session.workspace_id) || null,
        deviceName: this.name,
      });
    }
    return out;
  }
}

const feeds = new Map();

// A feed only changes on an event, so the rows are rebuilt on a change and not on every frame.
let feedsRev = 0;

/** @returns {void} */
function touchFeeds() {
  feedsRev++;
}

/** @type {{ rev: number, session: Wire.Session | null }} */
let newestLocal = { rev: -1, session: null };

// The newest local session that names a model, cached so a status draw costs no scan.
/** @returns {Wire.Session | null} */
export function newestLocalModelSession() {
  if (newestLocal.rev === feedsRev) return newestLocal.session;
  /** @type {Wire.Session | null} */
  let best = null;
  const feed = feeds.get(LOCAL);
  if (feed) {
    for (const it of feed.items.values()) {
      const s = it.session;
      if (!s || !s.model) continue;
      if (!best || (s.updated_at_ms || 0) > (best.updated_at_ms || 0)) best = s;
    }
  }
  newestLocal = { rev: feedsRev, session: best };
  return best;
}

// The live entry for one session, or null. This keeps the feed map inside this module.
/** @param {string} connKey @param {string} sessionId @returns {FeedItem | null} */
export function feedItem(connKey, sessionId) {
  const feed = feeds.get(connKey);
  return (feed && feed.items.get(sessionId)) || null;
}

/** @param {string} connKey @returns {DeviceFeed} */
export function feedOf(connKey) {
  let f = feeds.get(connKey);
  if (!f) {
    f = new DeviceFeed(connKey);
    feeds.set(connKey, f);
    touchFeeds();
  }
  return f;
}

/** @returns {SessionRow[]} */
function mergedRows() {
  /** @type {SessionRow[]} */
  const all = [];
  for (const f of feeds.values()) {
    for (const row of f.rows()) all.push(row);
  }
  all.sort((a, b) => (b.session.updated_at_ms || 0) - (a.session.updated_at_ms || 0));
  return all;
}

/** @param {SessionRow} row @returns {string} */
export function rowKey(row) {
  return row.connKey + "\0" + row.id;
}

/** @param {SessionRow} row @returns {string} */
export function rowLabel(row) {
  if (feeds.size <= 1 && row.connKey === LOCAL) return row.title;
  const name = row.deviceName || (row.connKey === LOCAL ? "local" : row.connKey.slice("remote:".length, "remote:".length + 7));
  return name + " · " + row.title;
}

/** @param {Wire.Session} s @returns {string} */
function sessionTitle(s) {
  const t = (s && s.title ? s.title : "").trim();
  return t !== "" ? t : "untitled";
}

// A one-cell activity mark: "!" needs attention, "●" working, "" idle.
  /** @param {FeedActivity} activity @returns {string} */
export function activityMark(activity) {
  const type = activity && activity.state ? activity.state.type : "idle";
  if (type === "waiting_permission") return "!";
  return type === "idle" ? "" : "●";
}

// The session's relative age, for the sidebar's right column.
/** @param {number} ms @returns {string} */
function relTime(ms) {
  if (!ms) return "";
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (s < 60) return "now";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// The sidebar row's second line: workspace and model.
/** @param {SessionRow} row @returns {string} */
function metaLabel(row) {
  const ws = row.workspace && row.workspace.title ? row.workspace.title : "";
  const model = row.session && row.session.model ? row.session.model : "";
  return [ws, model].filter(Boolean).join(" · ") || "—";
}

// --- panes --------------------------------------------------------------------------------
// A pane is a node-leaf view: it owns its rect, draws with draw(focused), and returns whether
// onKey(ev) consumed the key. The node tree assigns rects and routes focus.

// The sidebar: merged DeviceFeed rows, newest first, two lines each. Enter previews the pair.
export class SessionList {
  /** @param {SessionListOptions} opts */
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.list = new List({
      key: rowKey,
      itemHeight: 2,
      format: /** @param {SessionRow} row */ (row => this._format(row)),
      group: "YukeSession",
      selGroup: "YukeSessionSel",
    });
    this.onOpen = opts.onOpen || null;
    this._rev = -1;
    this.statusLabel = opts.statusLabel || (() => "");
    this.activeSession = opts.activeSession || (() => null);
  }

  /** @returns {string} */
  get name() {
    return "sessions";
  }

  /** @returns {void} */
  update() {
    if (this._rev === feedsRev) return;
    this._rev = feedsRev;
    this.list.setItems(mergedRows());
  }

  /** @returns {SessionRow | null} */
  current() {
    return this.list.selected();
  }

  // The keymap drives this widget, so a nav key needs no handler here.
  /** @returns {import("yuke:core").NavTarget} */
  navTarget() {
    return this.list;
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    const s = strokeOf(/** @type {Extract<HostEvent, { type: "key" }>} */ (ev));
    if (s === "enter") {
      this.open(this.list.selected(), "key");
      return true;
    }
    // `l`/`right` open and enter the chat, the way a vim window takes `l`.
    if (s === "l" || s === "right") {
      this.open(this.list.selected(), "go");
      return true;
    }
    return false;
  }

  // A left click selects a row and opens its pair, the same as Enter. A wheel step only moves.
  /** @param {Extract<HostEvent, { type: "mouse" }>} ev @returns {boolean} */
  onMouse(ev) {
    if (!this.list.onMouse(ev)) return false;
    if (ev.button === "left") this.open(this.list.selected(), "mouse");
    return true;
  }

  // `src` is "key" (preview, stay), "go" (jump in), or "mouse" (jump in).
  /** @param {SessionRow | null} row @param {string} src @returns {void} */
  open(row, src) {
    if (!row) return;
    if (this.onOpen) this.onOpen(row.connKey, row.id, src);
  }

  // A two-line row: an activity mark and title over a faint workspace and model. The active pair
  // prefixes its title with "▸", so the mark and the active cue stay independent.
  /** @param {SessionRow} row @returns {import("yuke:ui").ListItem} */
  _format(row) {
    const open = this.activeSession();
    const active = !!open && open.connKey === row.connKey && open.sessionId === row.id;
    const mark = activityMark(row.activity);
    return {
      lines: [
        {
          marker: mark || null,
          markerGroup: "YukeSessionMeta",
          markerSelGroup: "YukeSessionMetaSel",
          indent: 2,
          text: (active ? "▸ " : "") + rowLabel(row),
          right: relTime(row.session.updated_at_ms),
          group: "YukeSession",
          selGroup: "YukeSessionSel",
          rightGroup: "YukeSessionMeta",
          rightSelGroup: "YukeSessionMetaSel",
        },
        { indent: 2, text: metaLabel(row), group: "YukeSessionMeta", selGroup: "YukeSessionMetaSel" },
      ],
    };
  }

  /** @param {boolean} focused @returns {void} */
  draw(focused) {
    const { x, y, w: sw, h } = this.rect;
    if (sw <= 0 || h <= 0) {
      this.list.clearRect();
      return;
    }

    const pad = sw >= 4 ? 1 : 0;
    const iw = Math.max(0, sw - pad * 2);
    let row = y;

    if (row < y + h) {
      text(x + pad, row, clip("yuke", iw), "YukeBrand");
      row++;
    }
    if (row < y + h) {
      text(x + pad, row, clip(this.statusLabel(), iw), "YukeStatus");
      row++;
    }
    if (row < y + h) {
      text(x + pad, row, clip("─".repeat(iw), iw), "YukeRule");
      row++;
    }

    const footerY = y + h - 1;
    this._drawList(x + pad, row, iw, Math.max(0, footerY - row), focused);

    if (footerY >= y) {
      text(x + pad, footerY, clip("j/k move · ↵ open · ^k h/l pane", iw), "YukeFooter");
    }
  }

  // The rows, or an empty/status line. The List paints the two-line rows; the cursor shows only
  // when the pane is focused.
  /** @param {number} x @param {number} top @param {number} w @param {number} h @param {boolean} focused @returns {void} */
  _drawList(x, top, w, h, focused) {
    if (h <= 0 || w <= 0) {
      this.list.clearRect();
      return;
    }

    const conns = client.connections();
    const ready = conns.some((c) => c.state === "ready");
    const busy = conns.some((c) => c.state === "connecting" || c.state === "closing");
    if (!ready) {
      text(x, top, clip(busy ? "…" : "not connected", w), "YukeEmpty");
      this.list.clearRect();
      return;
    }
    if (this.list.items.length === 0) {
      const loading = [...feeds.values()].some((f) => !f.loaded);
      text(x, top, clip(loading ? "loading…" : "no sessions", w), "YukeEmpty");
      this.list.clearRect();
      return;
    }

    this.list.drawCursor = focused;
    this.list.draw({ x, y: top, w, h });
  }
}

// The feed registrations. The owner supplies a device name, because the roster belongs to it.
export const sidebarPlugin = {
  name: "sidebar",
  /** @param {import("yuke:ext").Context} ctx @param {unknown} config @returns {void} */
  apply(ctx, config) {
    const cfg = /** @type {SidebarConfig} */ (config || {});
    const deviceName = cfg.deviceName || (() => "");
    if (cfg.onCatalogChanged) {
      const previous = onCatalogChanged;
      onCatalogChanged = cfg.onCatalogChanged;
      ctx.effect(() => () => {
        onCatalogChanged = previous;
      });
    }

    ctx.on("index.changed", /** @param {NativeIndexEvent} ev @returns {void} */ (ev) => {
      if (!ev || !ev.connKey) return;
      const f = feeds.get(ev.connKey);
      if (!f) return;
      f.fold(ev);
      root.invalidate();
    });

    ctx.on("conn.changed", /** @param {NativeConnEvent} ev @returns {void} */ (ev) => {
      if (!ev || !ev.key) return;
      if (ev.kind === "ready") {
        const f = feedOf(ev.key);
        if (!f.name) {
          f.name = deviceName(ev.key);
          touchFeeds();
        }
        f.learnWorkspaces(ev.workspaces);
        client.sessionList(ev.key).then(
          (res) => {
            f.seed(res);
            root.invalidate();
          },
          () => root.invalidate(),
        );
        root.invalidate();
        return;
      }
      if (ev.kind === "close") {
        const f = feeds.get(ev.key);
        if (f) f.clear();
        feeds.delete(ev.key);
        touchFeeds();
        root.invalidate();
      }
    });
  },
};
