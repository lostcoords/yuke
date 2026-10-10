// The session layer: the engine sessions the panes show, their pins, the session list, the model a new session takes,
// the current pane, and the session commands. Any pane that holds a `Session` gets every feature built on this layer.
import { root } from "yuke:internal/core";
import { events, notify } from "yuke:internal/kernel";
import { term } from "yuke:internal/native/term";
import { client } from "yuke:internal/client";
import { Refresh } from "yuke:internal/refresh";
import { openModelPicker, openSessionFinder } from "yuke:internal/session-ui";
import { errorText } from "yuke:internal/format";

/** @import { Composer } from "yuke:internal/ui" */
/** @import { Transcript } from "yuke:internal/transcript" */
/** @import { ViewLike } from "./types/core.js" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Context } from "yuke:internal/ext" */
/** @typedef {Wire.CreateSession} CreateSessionDraft */
/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_tokens: number, pending_compaction: null }} FeedActivity */
/**
 * One entry of the session list: the session record and its activity.
 * @typedef {{ session: Wire.Session, activity: FeedActivity }} FeedItem
 */
/** @typedef {{ id: string, title: string, activity: FeedActivity, session: Wire.Session }} SessionRow */
/** @typedef {{ model: string | null, reasoning: string }} ModelDefaults */
/**
 * A pane that shows a session. It has a `session` and a `transcript`, and a `composer` when it takes input. `ChatView` is one.
 * @typedef {ViewLike & { session: Session, transcript: Transcript, composer?: Composer }} SessionPane
 */

// This module emits these names, so it declares them.
events.declare(["session.current.changed", "model.changed", "activity.changed"]);

// `/skill:<name> [arguments]`: the name ends at the first whitespace character, and the trimmed rest is the arguments text.
/** @param {string} text @returns {{ name: string, args: string } | null} */
function parseSkillLine(text) {
  const match = /^\/skill:([a-z0-9-]+)(?:\s+([\s\S]*))?$/.exec(text.trim());
  const name = match?.[1];
  return name ? { name, args: (match[2] || "").trim() } : null;
}

// The text when the content is one text part and nothing else, so an attachment never reads as a command.
/** @param {readonly Wire.ContentPart[]} content @returns {string | null} */
export function soleText(content) {
  const only = content.length === 1 ? content[0] : null;
  return only && only.type === "text" ? only.text : null;
}

/**
 * One engine session in the TUI: its id, its pin, and the panes that show it. A draft has a null `sessionId` until its first input creates the session.
 * Panes on the same id share one `Session`. `showSession` moves one pane to a `Session` or a session id; `open` moves every pane of this session.
 */
export class Session {
  constructor() {
    /**
     * The engine session id, or null for a draft. Only this class writes it, because the id and the native pin change together.
     * @type {string | null}
     */
    this.sessionId = null;
    /** True while the create request of this draft is in flight. */
    this.creating = false;
    this.gen = 0;
    // An array, so a stream delta walks it by index and allocates no iterator.
    /**
     * Every pane that shows this session. A pane enters through `join` and leaves through `leave`.
     * @type {SessionPane[]}
     */
    this.views = [];
    /**
     * The live activity, or null while the session holds no pin. Each activity fact reads it again and emits `activity.changed`.
     * @type {Wire.SessionActivity | null}
     */
    this.activity = null;
  }

  /**
   * Pin session `id` and show it in every pane of this session. The engine counts pins, so each open needs exactly one release.
   * An open of the current id only reloads the transcripts. When the engine refuses `id`, the session keeps its old id, shows an error notification, and returns false.
   * @param {string} id @returns {boolean}
   */
  open(id) {
    if (this.sessionId === id) {
      this.reload();
      return true;
    }
    // A later open cannot reuse a stale creation.
    this.gen++;
    this.creating = false;
    if (!client.sessionOpen(id)) {
      notify("error", "open failed · session unavailable", "session");
      root.invalidate();
      return false;
    }
    this.release();
    this.sessionId = id;
    this.refreshActivity();
    // Message ids repeat across sessions, so the old render must go before the new outline lands.
    for (const view of this.views) view.transcript.setOutline([], null);
    this.reload();
    this.checkContext(id);
    notifyCurrent();
    return true;
  }

  /**
   * Warn once per open when AGENTS.md or the skills changed on disk after the session stored them. The user decides on /reload.
   * @param {string} id
   */
  checkContext(id) {
    const token = this.gen;
    client.sessionCheckContext(id).then((item) => {
      // A later open moves the generation, so a slow answer for an earlier open stays silent.
      if (token !== this.gen || this.sessionId !== id) return;
      const changes = item.context_changes;
      if (!changes || (!changes.instructions && !changes.skills)) return;
      const what = changes.instructions && changes.skills ? "AGENTS.md and skills" : changes.instructions ? "AGENTS.md" : "skills";
      notify("warn", what + " changed on disk. Run /reload to update this session.", "session");
      root.invalidate();
    }).catch(() => {});
  }

  /**
   * Send composer content to the session. A draft creates the session with this content as its first input.
   * One text part of the form `/skill:<name> [arguments]` invokes that skill.
   * It returns false when the composer must keep the content: a create is already in flight, or no workspace directory exists.
   * A later failure puts the content back into `composer` and shows an error notification.
   * @param {readonly Wire.ContentPart[]} content @param {Composer} composer @returns {boolean}
   */
  send(content, composer) {
    const text = soleText(content);
    const invocation = text === null ? null : parseSkillLine(text);
    if (!this.sessionId) return this.startChat(invocation ? { type: "skill", name: invocation.name, ...(invocation.args ? { arguments: invocation.args } : {}) } : { type: "content", content }, composer);
    const snap = composer.snapshot();
    const sent = invocation ? client.sessionSendSkill(this.sessionId, invocation.name, invocation.args) : client.sessionSendInput(this.sessionId, content);
    sent.catch((e) => {
      composer.restore(snap);
      notify("error", "send failed · " + errorText(e), "session");
    });
    return true;
  }

  /**
   * The model selector that the next input goes to: the model of the session, else the default for a new chat. "" when no model is known.
   * @returns {string}
   */
  modelSelector() {
    const item = this.sessionId ? feedItem(this.sessionId) : null;
    return (item && item.session.model) || defaultModel().model || "";
  }

  /**
   * Send the next input to `model` with `reasoning`, and make the pair the default for a new chat. On success it emits `model.changed`.
   * An open session takes the choice only after the engine accepts the patch, so a refused choice changes nothing. A run in flight keeps its settings until the next turn.
   * @param {Wire.ModelInfo} model @param {string} reasoning @returns {void}
   */
  setModel(model, reasoning) {
    notify("info", model.name + (reasoning ? " · " + reasoning : ""), "model");
    const sessionId = this.sessionId;
    const choose = () => {
      modelDefaults.model = model.selector;
      modelDefaults.reasoning = reasoning;
      // A pane that holds an attachment may have something to say about the model it now sends to.
      events.emit("model.changed", { model, sessionId });
      root.invalidate();
    };
    if (!sessionId) return choose();
    root.invalidate();
    // A run in flight keeps the settings it started with, so the move lands on the next turn.
    client.sessionPatch(sessionId, { model: model.selector, reasoning }).then(choose, (e) => {
      notify("error", errorText(e), "model");
      root.invalidate();
    });
  }

  /** Read the activity again and emit `activity.changed`. The read finds the activity only while the session holds its pin. */
  refreshActivity() {
    const id = this.sessionId;
    if (!id) return;
    this.activity = client.sessionActivity(id);
    events.emit("activity.changed", id, this.activity);
    root.invalidate();
  }

  /** Set the activity to null and emit `activity.changed`. Call it before the session stops holding its id. */
  forgetActivity() {
    if (!this.sessionId || this.activity === null) return;
    this.activity = null;
    events.emit("activity.changed", this.sessionId, null);
    root.invalidate();
  }

  /** Stop the current run. The queue stays, so an interrupt never drops a message the user already typed. A draft ignores it. */
  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.sessionId).catch(() => {});
  }

  /**
   * Read the outline again into `views` after a structural change. The default is every pane of this session. A draft or an unreadable outline leaves the panes as they are.
   * @param {readonly SessionPane[]} [views]
   */
  reload(views = this.views) {
    if (!this.sessionId) return;
    const o = client.sessionOutline(this.sessionId);
    if (!o || !Array.isArray(o.messages)) return;
    for (const view of views) view.transcript.setOutline(o.messages, o.active || null);
    root.invalidate();
  }

  /**
   * Apply a streaming delta: rebuild only the streaming message `id`, or only its part `partId` when the digest names one.
   * @param {number} id @param {number} [partId]
   */
  active(id, partId) {
    const views = this.views;
    for (let i = 0; i < views.length; i++) /** @type {SessionPane} */ (views[i]).transcript.setActive(id, partId);
    root.invalidate();
  }

  /** Rebuild the running tool header, because its elapsed time reads the wall clock instead of the stored part. */
  refreshElapsed() {
    const state = this.activity?.state;
    if (!state || state.type !== "running_tool") return;
    const views = this.views;
    for (let i = 0; i < views.length; i++) /** @type {SessionPane} */ (views[i]).transcript.refreshRow(state.message_id, state.part_id);
  }

  /**
   * Create the session with its first input, then open the new session. It returns false when a create is in flight or no workspace directory exists.
   * On a failure the composer takes the input back.
   * @param {Wire.Input} input @param {Composer} composer @returns {boolean}
   */
  startChat(input, composer) {
    if (this.creating) return false;
    if (!term.cwd) {
      notify("error", "no workspace directory", "session");
      return false;
    }
    const snap = composer.snapshot();
    const d = defaultModel();
    const params = /** @type {CreateSessionDraft} */ ({ workspace_path: term.cwd, ...(d.model ? { model: d.model } : {}), ...(d.reasoning ? { reasoning: d.reasoning } : {}), initial_input: input });
    const token = ++this.gen;
    this.creating = true;
    client
      .sessionCreate(params)
      .then((r) => {
        // Navigation leaves this draft; accepted work still belongs to the new session.
        if (token !== this.gen) return null;
        this.open(r.session.id);
        return null;
      })
      .catch((e) => {
        // A cancelled create must not restore an input into a view the user already moved on from.
        if (token !== this.gen) return;
        composer.restore(snap);
        notify("error", "new chat failed · " + errorText(e), "session");
      })
      .then(() => {
        if (token === this.gen) this.creating = false;
      });
    return true;
  }

  /** The engine removed the session. Make this session a draft again and clear its panes back to the placeholder. */
  sessionGone() {
    this.forgetActivity();
    this.sessionId = null;
    for (const view of this.views) view.transcript.setOutline([], null);
    root.invalidate();
    notifyCurrent();
  }

  /** Drop the pin. The engine counts pins, so an unrelated open of the same id keeps its own pin. */
  release() {
    if (!this.sessionId) return;
    client.sessionClose(this.sessionId);
    this.forgetActivity();
  }

  /**
   * A pane starts to show this session. The first pane adds the session to `sessions`, so a session that no pane shows is never there.
   * Throws when the pane already joined. To move a pane, use `showSession`.
   * @param {SessionPane} view
   */
  join(view) {
    if (this.views.indexOf(view) >= 0) throw new Error("session: a view joins once");
    if (this.views.length === 0) sessions.push(this);
    this.views.push(view);
  }

  /**
   * A pane stops showing this session. The last pane releases the pin, makes the session a draft, and removes it from `sessions`.
   * Throws when the pane did not join.
   * @param {SessionPane} view
   */
  leave(view) {
    const at = this.views.indexOf(view);
    if (at < 0) throw new Error("session: a view leaves only after it joins");
    this.views.splice(at, 1);
    if (this.views.length !== 0) return;
    this.gen++;
    this.creating = false;
    this.release();
    this.sessionId = null;
    sessions.splice(sessions.indexOf(this), 1);
  }
}

// An array, so a stream delta and a frame walk it by index and allocate no iterator.
/**
 * Every session that a pane shows, drafts included. An event reaches each session it names once, however many panes show it.
 * `join` and `leave` keep this list. Do not write it.
 * @type {Session[]}
 */
export const sessions = [];

// The session list the finder and the default model read. The first reader starts one `session.list` read, so nothing reads
// while nobody looks. After that a summary change reads its one entry, and only an overflow marks the whole list stale.
class SessionFeed {
  constructor() {
    /** @type {Map<string, FeedItem>} */
    this.items = new Map();
    // The list only changes on a read, so a reader caches against this count and not against every frame.
    this.rev = 0;
    // The list may miss a change, so its next reader reads it again. It starts unread.
    this.stale = true;
    this._refresh = new Refresh(
      () => client.sessionList().then((r) => this.seed(r), () => { this.stale = true; }),
      // A refused read redraws nothing, or the redraw would read again while the engine refuses.
      () => { if (!this.stale) root.invalidate(); },
    );
  }

  /** @param {Wire.SessionListResult} listResult @returns {void} */
  seed(listResult) {
    this.rev++;
    this.items.clear();
    for (const it of listResult.items) this.items.set(it.session.id, it);
  }

  // Read the list again. A burst shares one read and one follow-up catches changes during it.
  /** @returns {Promise<void>} */
  refresh() {
    this.stale = false;
    return this._refresh.run();
  }

  // Read one entry after its summary changed. `session.get` answers inline, so reads of one entry settle in order.
  // A stale list waits for its next reader, and a list read in flight may predate the change, so it reads again.
  /** @param {string} id @returns {void} */
  refreshItem(id) {
    if (this.stale) return;
    if (this._refresh.loading) {
      this.refresh();
      return;
    }
    client.sessionGet(id).then((item) => {
      this.items.set(id, item);
      this.rev++;
      root.invalidate();
    }).catch(() => {});
  }

  /** @returns {SessionRow[]} */
  rows() {
    /** @type {SessionRow[]} */
    const out = [];
    for (const it of this.items.values()) {
      const title = it.session.title.trim();
      out.push({ id: it.session.id, title: title !== "" ? title : "untitled", activity: it.activity, session: it.session });
    }
    return out;
  }
}

const feed = new SessionFeed();

// The listed entry for one session, or null.
/** @param {string} sessionId @returns {FeedItem | null} */
export function feedItem(sessionId) {
  // A status draw reads this each frame, so the staleness check stays inline.
  if (feed.stale) feed.refresh();
  return feed.items.get(sessionId) || null;
}

// The model a new session starts with. A named session moves to the same choice.
/** @type {ModelDefaults} */
const modelDefaults = { model: null, reasoning: "" };

// The model of the newest session that names one, for the list revision it was read from.
/** @type {{ rev: number, defaults: ModelDefaults | null }} */
let newestLocal = { rev: -1, defaults: null };

// Without a choice this run, the newest session that names a model gives the model and reasoning, so a restart keeps working.
// A status draw reads this each frame, so the answer is cached against the list revision and a frame costs no scan.
/** @returns {ModelDefaults} */
export function defaultModel() {
  if (feed.stale) feed.refresh();
  if (modelDefaults.model) return modelDefaults;
  if (newestLocal.rev !== feed.rev) {
    /** @type {Wire.Session | null} */
    let best = null;
    for (const it of feed.items.values()) {
      const s = it.session;
      if (!s.model) continue;
      if (!best || (s.updated_at_ms || 0) > (best.updated_at_ms || 0)) best = s;
    }
    newestLocal = { rev: feed.rev, defaults: best ? { model: best.model, reasoning: best.reasoning } : null };
  }
  return newestLocal.defaults || modelDefaults;
}

// The session that holds `id`, or null. Views on one id share one session.
/** @param {string} id @returns {Session | null} */
function sessionOf(id) {
  for (let i = 0; i < sessions.length; i++) {
    const held = /** @type {Session} */ (sessions[i]);
    if (held.sessionId === id) return held;
  }
  return null;
}

// A session pane is a view that shows a session. Any view joins by holding one.
/** @param {unknown} view @returns {view is SessionPane} */
function isSessionPane(view) {
  return /** @type {{ session?: unknown } | null} */ (view)?.session instanceof Session;
}

/**
 * Show `session` in `view`: a `Session`, or the id of an engine session. The pane leaves its old session, and the last pane of that session releases it.
 * An id that a pane already shows shares that `Session` and its pin. When the engine refuses an id, the pane stays as it is and an error notification shows.
 * Nothing happens when the pane already shows the session.
 * @param {SessionPane} view @param {Session | string} session @returns {void}
 */
export function showSession(view, session) {
  if (typeof session === "string") {
    const held = sessionOf(session);
    if (held) session = held;
    else {
      const opened = new Session();
      if (!opened.open(session)) return;
      session = opened;
    }
  }
  if (view.session === session) return;
  view.session.leave(view);
  view.session = session;
  session.join(view);
  // Message ids repeat across sessions, so the old render must go before the new outline lands.
  // Only the joining view loads it, so a view already on the session keeps its selection.
  view.transcript.setOutline([], null);
  session.reload([view]);
  root.invalidate();
  notifyCurrent();
}

// The current pane: the pane that holds a session and had focus last, while it stays in the tree. Session commands,
// the status bar, and `session.current.changed` read it, so a focused pane that holds no session leaves it in place.
/** @type {SessionPane | null} */
let current = null;

/**
 * The pane that holds a session and had focus last, or null when no pane holds a session.
 * A focused pane with no session does not change it. `session.current.changed` announces a change of its session id.
 * @returns {SessionPane | null}
 */
export function currentPane() {
  return current;
}

/**
 * The session of `currentPane()`, or null when there is no current pane. A draft has a null `sessionId`.
 * @returns {Session | null}
 */
export function currentSession() {
  return current ? current.session : null;
}

/** @type {string | null} */
let announced = null;

// Announce a change of the current session id once, so a repeat open of the same session stays quiet.
function notifyCurrent() {
  const id = current?.session.sessionId ?? null;
  if (id === announced) return;
  announced = id;
  events.emit("session.current.changed");
}

// The focused pane when it holds a session, else the first session pane in the tree, else null.
/** @returns {SessionPane | null} */
function fallbackPane() {
  if (isSessionPane(root.active)) return root.active;
  for (const leaf of root.root_node ? root.root_node.leaves() : []) {
    const view = leaf.shape.type === "leaf" ? leaf.shape.view : null;
    if (isSessionPane(view)) return view;
  }
  return null;
}

/**
 * The list entry of the current session with its live activity. Null when no current pane exists, the pane shows a draft, or the list has no entry for the session yet.
 * @returns {FeedItem | null}
 */
export function currentEntry() {
  const id = current?.session.sessionId;
  if (!id) return null;
  const item = feedItem(id);
  if (!item) return null;
  const activity = current?.session.activity;
  return activity ? { session: item.session, activity } : item;
}

export const sessionsPlugin = {
  name: "sessions",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The current pane follows the focus; a focused pane that holds no session leaves it in place.
      ctx.on("pane.focused", (view) => {
        if (!isSessionPane(view)) return;
        current = view;
        notifyCurrent();
      });
      // A closed current pane hands over to the focused pane, else to the first session pane left in the tree.
      // A closed pane leaves its session, and the last view releases the pin, or the engine never evicts it.
      ctx.on("pane.closed", (view) => {
        if (!current || current === view) {
          current = fallbackPane();
          notifyCurrent();
        }
        if (isSessionPane(view)) view.session.leave(view);
      });
      // Nothing reads the activity once this block leaves, so a stale "working" must not keep the indicator ticking.
      ctx.effect(() => () => {
        current = null;
        notifyCurrent();
        for (const session of sessions) session.forgetActivity();
      });

      // Views on one session share it, so the event reaches that session once and it updates every view.
      // The digest names the activity fact and the session reads the projection, so a burst costs one read per frame.
      ctx.on("session.changed", (ev) => {
        // A removed session leaves the list now; a summary change reads its one entry.
        if (ev.kind === "gone") {
          if (feed.items.delete(ev.session)) feed.rev++;
        } else if (ev.facts.indexOf("session.summary_changed") >= 0) feed.refreshItem(ev.session);
        for (let i = 0; i < sessions.length; i++) {
          const session = /** @type {Session} */ (sessions[i]);
          if (session.sessionId !== ev.session) continue;
          if (ev.kind === "gone") {
            session.sessionGone();
            continue;
          }
          // A quiet digest changes only state outside the transcript.
          if (ev.kind === "active") session.active(/** @type {number} */ (ev.id), ev.part);
          else if (ev.kind !== "quiet") session.reload();
          if (ev.facts.indexOf("session.activity_changed") >= 0) session.refreshActivity();
        }
      });

      // The list missed every change while this block was away, so its next reader reads it again.
      feed.stale = true;
      // An overflow drops facts, so the whole list is stale and the next frame's reader reads it again.
      ctx.on("index.changed", (ev) => {
        if (!ev.overflow) return;
        feed.stale = true;
        root.invalidate();
      });

      // The model the current session sends to, on the right of the status bar.
      ctx.tui.status.add({
        side: "right",
        order: 10,
        render: () => (current ? current.session.modelSelector() : defaultModel().model || ""),
      });

      ctx.tui.command.add("session:interrupt", { when: () => current?.session.sessionId != null, desc: "stop the run", slash: true, run: () => current?.session.interrupt() });
      ctx.tui.command.add("ui:sessions", {
        desc: "open a session",
        slash: true,
        run: () => feed.refresh().then(() => {
          const rows = feed.rows().filter((row) => row.session.origin.type !== "child").sort((a, b) => (b.session.updated_at_ms || 0) - (a.session.updated_at_ms || 0));
          // A pane that holds a session has its live activity, so the finder reads that before the listed one.
          openSessionFinder(ctx, rows, (id) => sessionOf(id)?.activity, (id) => { if (current) showSession(current, id); });
        }),
      });
      ctx.tui.command.add("model:pick", {
        desc: "choose the model for the next chat",
        slash: "model",
        args: true,
        run: (/** @type {string | undefined} */ query) => {
          if (!current) return;
          const entry = currentEntry();
          openModelPicker(ctx, current, entry ? entry.session.model : null, query);
        },
      });
      ctx.tui.command.add("context:reload", {
        desc: "rescan AGENTS.md and skills for this chat",
        slash: true,
        run: () => {
          const id = current?.session.sessionId;
          if (!id) return notify("info", "no open chat", "session");
          client.sessionReloadContext(id).then((r) => {
            notify("info", "Context reloaded: " + r.instruction_sources.length + " AGENTS.md, " + r.skills.length + " skills.", "context");
            root.invalidate();
          }).catch((e) => {
            notify("error", "Context reload failed: " + errorText(e), "context");
          });
        },
      });
      ctx.tui.command.add("context:compact", {
        desc: "summarize the earlier history of this chat",
        slash: true,
        run: () => {
          const id = current?.session.sessionId;
          if (!id) return notify("info", "no open chat", "session");
          client.sessionCompact(id).then((r) => {
            notify("info", r.status === "started" ? "Compacting the context." : "Compaction waits for the active run.", "context");
            root.invalidate();
          }).catch((e) => {
            notify("error", "Compaction failed: " + errorText(e), "context");
          });
        },
      });
      ctx.tui.keymap.add({ "ctrl+f": "ui:sessions", "ctrl+c": "session:interrupt" });
    });
  },
};
