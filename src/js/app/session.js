// The session layer: the engine sessions the panes show, their pins, the session list, the model a new session takes,
// the current pane, and the session commands. Any pane that holds a `Session` gets every feature built on this layer.
import { root, command } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { term } from "yuke:internal/native/term";
import { ui } from "yuke:internal/ui";
import { client } from "yuke:internal/client";
import { notice } from "yuke:internal/notice";
import { Refresh } from "yuke:internal/refresh";
import { catalogOf, reloadCatalog, providerState, providerStateLabel } from "yuke:internal/catalog";
import { errorText } from "yuke:internal/format";

/** @import { Composer } from "yuke:internal/ui" */
/** @import { Transcript } from "yuke:internal/transcript" */
/** @import { MessagePart } from "yuke:internal/native/engine" */
/** @import { ViewLike } from "./types/core.js" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Context } from "yuke:internal/ext" */
/** @typedef {Wire.CreateSession} CreateSessionDraft */
/** @typedef {Wire.SessionActivity | { state: { type: "idle" }, queued: number, context_usage: Wire.TokenUsage, pending_compaction: null }} FeedActivity */
/** @typedef {{ session: Wire.Session, activity: FeedActivity }} FeedItem */
/** @typedef {{ id: string, title: string, activity: FeedActivity, session: Wire.Session }} SessionRow */
/** @typedef {{ model: string | null, reasoning: string }} ModelDefaults */
/** @typedef {ViewLike & { session: Session, transcript: Transcript, composer?: Composer }} SessionPane */

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

// One engine session in the TUI: its id, its pin, and the views that show it. A draft has no id until its first input creates one.
export class Session {
  constructor() {
    // Use open, or show a view another session, to change the id and its native pin.
    /** @type {string | null} */
    this.sessionId = null;
    this.creating = false;
    this.gen = 0;
    // Every pane that shows this session. A pane joins by adding itself and leaves through `leave`.
    /** @type {Set<SessionPane>} */
    this.views = new Set();
    // The live activity while the session holds its pin, read back after each activity fact.
    /** @type {Wire.SessionActivity | null} */
    this.activity = null;
    sessions.add(this);
  }

  /** @param {number} id @returns {readonly MessagePart[]} */
  partsOf(id) {
    return this.sessionId ? client.sessionParts(this.sessionId, id) : [];
  }

  /** @param {number} id @param {number} partId @param {MessagePart} [previous] @returns {MessagePart | null} */
  partOf(id, partId, previous) {
    return this.sessionId ? client.sessionPart(this.sessionId, id, partId, previous) : null;
  }

  /** @param {number} id @param {number} partId @param {string} field @param {number} [offset] @param {number} [limit] @returns {{ text: string, next: number | null }} */
  partTextPage(id, partId, field, offset, limit) {
    return this.sessionId ? client.partTextPage(this.sessionId, id, partId, field, offset, limit) : { text: "", next: null };
  }

  // Pin `id` and show it in every view. The engine counts pins, so one open owes exactly one release. False when the engine refuses.
  /** @param {string} id @returns {boolean} */
  open(id) {
    if (this.sessionId === id) {
      this.reload();
      return true;
    }
    // A later open cannot reuse a stale creation.
    this.gen++;
    this.creating = false;
    if (!client.sessionOpen(id)) {
      notice.show("open failed · session unavailable");
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

  // Tell the user once per open when the files behind the stored snapshots changed. The user decides on /reload.
  /** @param {string} id */
  checkContext(id) {
    const token = this.gen;
    client.sessionCheckContext(id).then((item) => {
      // A later open moves the generation, so a slow answer for an earlier open stays silent.
      if (token !== this.gen || this.sessionId !== id) return;
      const changes = item.context_changes;
      if (!changes || (!changes.instructions && !changes.skills)) return;
      const what = changes.instructions && changes.skills ? "AGENTS.md and skills" : changes.instructions ? "AGENTS.md" : "skills";
      notice.show(what + " changed on disk. Run /reload to update this session.");
      root.invalidate();
    }).catch(() => {});
  }

  // Send composer content into the session, or return false so the composer keeps it. A failure restores that composer.
  /** @param {readonly Wire.ContentPart[]} content @param {Composer} composer @returns {boolean} */
  send(content, composer) {
    const text = soleText(content);
    const invocation = text === null ? null : parseSkillLine(text);
    if (!this.sessionId) return this.startChat(invocation ? { type: "skill", name: invocation.name, ...(invocation.args ? { arguments: invocation.args } : {}) } : { type: "content", content }, composer);
    const snap = composer.snapshot();
    const sent = invocation ? client.sessionSendSkill(this.sessionId, invocation.name, invocation.args) : client.sessionSendInput(this.sessionId, content);
    sent.catch((e) => {
      composer.restore(snap);
      notice.show("send failed · " + errorText(e));
    });
    return true;
  }

  // The model the next input goes to: the session's own, or the default a new chat takes.
  /** @returns {string} */
  modelSelector() {
    const item = this.sessionId ? feedItem(this.sessionId) : null;
    return (item && item.session.model) || defaultModel().model || "";
  }

  // Send the next input to `model`, and make it the default a new chat takes.
  /** @param {Wire.ModelInfo} model @param {string} reasoning @returns {void} */
  setModel(model, reasoning) {
    const previous = { ...modelDefaults };
    modelDefaults.model = model.selector;
    modelDefaults.reasoning = reasoning;
    notice.show("model · " + model.name + (reasoning ? " · " + reasoning : ""));
    const sessionId = this.sessionId;
    // A pane that holds an attachment may have something to say about the model it now sends to.
    events.emit("model.changed", { model, sessionId });
    root.invalidate();
    if (!sessionId) return;
    // A run in flight keeps the settings it started with, so the move lands on the next turn.
    client.sessionPatch(sessionId, { model: model.selector, reasoning }).then(() => root.invalidate()).catch((e) => {
      // The engine refused, so the default must not keep a choice the engine rejected.
      Object.assign(modelDefaults, previous);
      notice.show("model · " + errorText(e));
      root.invalidate();
    });
  }

  // Read the activity again. The pin makes it readable, so a read while the session holds none finds nothing.
  refreshActivity() {
    const id = this.sessionId;
    if (!id) return;
    this.activity = client.sessionActivity(id);
    events.emit("activity.changed", id, this.activity);
    root.invalidate();
  }

  // The session is about to stop holding its id, so the activity leaves with it.
  forgetActivity() {
    if (!this.sessionId || this.activity === null) return;
    this.activity = null;
    events.emit("activity.changed", this.sessionId, null);
    root.invalidate();
  }

  // Stop the run and keep the queue, so an interrupt never drops a message the user already typed.
  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.sessionId).catch(() => {});
  }

  // Re-pull the outline into `views` on a structural change; a closed session must not empty them.
  /** @param {Iterable<SessionPane>} [views] */
  reload(views = this.views) {
    if (!this.sessionId) return;
    const o = client.sessionOutline(this.sessionId);
    if (!o || !Array.isArray(o.messages)) return;
    for (const view of views) view.transcript.setOutline(o.messages, o.active || null);
    root.invalidate();
  }

  // A draft delta: re-wrap only the streaming message `id`, or only its part `partId` when the digest names one.
  /** @param {number} id @param {number} [partId] */
  active(id, partId) {
    for (const view of this.views) view.transcript.setActive(id, partId);
    root.invalidate();
  }

  // Accept the session and first input together, then open the accepted session. The composer takes the input back on failure.
  /** @param {Wire.Input} input @param {Composer} composer @returns {boolean} */
  startChat(input, composer) {
    if (this.creating) return false;
    if (!term.cwd) {
      notice.show("no workspace directory");
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
        notice.show("new chat failed · " + errorText(e));
      })
      .then(() => {
        if (token === this.gen) this.creating = false;
      });
    return true;
  }

  // The engine lost the session. Clear its views back to the placeholder.
  sessionGone() {
    this.forgetActivity();
    this.sessionId = null;
    for (const view of this.views) view.transcript.setOutline([], null);
    root.invalidate();
    notifyCurrent();
  }

  // Drop the pin. The engine counts pins, so an unrelated open of the same id elsewhere keeps it.
  release() {
    if (!this.sessionId) return;
    client.sessionClose(this.sessionId);
    this.forgetActivity();
  }

  // A view stops showing this session. The last view releases the pin and takes the session out of the registry.
  /** @param {SessionPane} view */
  leave(view) {
    this.views.delete(view);
    if (this.views.size !== 0) return;
    this.gen++;
    this.creating = false;
    this.release();
    this.sessionId = null;
    sessions.delete(this);
  }
}

// Every live session, drafts too, so an event reaches each session it names once, however many views show it.
/** @type {Set<Session>} */
export const sessions = new Set();

// The session list the finder and the default model read. It keeps no copy of the store: a summary change marks it stale,
// and the next reader starts one `session.list` read, so nothing reads while nobody looks.
class SessionFeed {
  constructor() {
    /** @type {Map<string, FeedItem>} */
    this.items = new Map();
    // The list only changes on a read, so a reader caches against this count and not against every frame.
    this.rev = 0;
    // The changes seen, and the change count the last requested read covers. The list starts one change behind.
    this.changes = 1;
    this.asked = 0;
    this._refresh = new Refresh(
      () => client.sessionList().then((r) => this.seed(r)),
      () => root.invalidate(),
    );
  }

  get loading() {
    return this._refresh.loading;
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
    this.asked = this.changes;
    return this._refresh.run();
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

/** @returns {SessionFeed} */
export function feedOf() {
  return feed;
}

// The listed entry for one session, or null.
/** @param {string} sessionId @returns {FeedItem | null} */
export function feedItem(sessionId) {
  // A status draw reads this each frame, so the staleness check stays inline.
  if (feed.asked !== feed.changes) feed.refresh();
  return feed.items.get(sessionId) || null;
}

/** @type {{ rev: number, session: Wire.Session | null }} */
let newestLocal = { rev: -1, session: null };

// The newest session that names a model, cached so a status draw costs no scan.
/** @returns {Wire.Session | null} */
export function newestLocalModelSession() {
  if (feed.asked !== feed.changes) feed.refresh();
  if (newestLocal.rev === feed.rev) return newestLocal.session;
  /** @type {Wire.Session | null} */
  let best = null;
  for (const it of feed.items.values()) {
    const s = it.session;
    if (!s.model) continue;
    if (!best || (s.updated_at_ms || 0) > (best.updated_at_ms || 0)) best = s;
  }
  newestLocal = { rev: feed.rev, session: best };
  return best;
}

// The model a new session starts with. A named session moves to the same choice.
/** @type {ModelDefaults} */
const modelDefaults = { model: null, reasoning: "" };

// Without a choice this run, the newest session names the model and reasoning, so a restart keeps working.
/** @returns {ModelDefaults} */
export function defaultModel() {
  if (modelDefaults.model) return modelDefaults;
  const s = newestLocalModelSession();
  if (s && s.model) return { model: s.model, reasoning: s.reasoning };
  return modelDefaults;
}

// The session that holds `id`, or null. Views on one id share one session.
/** @param {string} id @returns {Session | null} */
function sessionOf(id) {
  for (const held of sessions) if (held.sessionId === id) return held;
  return null;
}

// A session pane is a view that shows a session. Any view joins by holding one.
/** @param {unknown} view @returns {view is SessionPane} */
function isSessionPane(view) {
  return /** @type {{ session?: unknown } | null} */ (view)?.session instanceof Session;
}

// Show `session` in `view`. The old session leaves, and its last view releases it.
/** @param {SessionPane} view @param {Session} session @returns {void} */
export function showSession(view, session) {
  if (view.session === session) return;
  view.session.leave(view);
  view.session = session;
  session.views.add(view);
  // Message ids repeat across sessions, so the old render must go before the new outline lands.
  // Only the joining view loads it, so a view already on the session keeps its selection.
  view.transcript.setOutline([], null);
  session.reload([view]);
  root.invalidate();
  notifyCurrent();
}

// Open session `id` in `view`. A view on the same id already holds it, so the two share one session and one pin.
/** @param {SessionPane} view @param {string} id @returns {void} */
export function openSession(view, id) {
  const held = sessionOf(id);
  if (held) return showSession(view, held);
  const session = new Session();
  if (session.open(id)) showSession(view, session);
  else sessions.delete(session);
}

// The current pane: the pane that holds a session and had focus last, while it stays in the tree. Session commands,
// the status bar, and `session.current.changed` read it, so a focused pane that holds no session leaves it in place.
/** @type {SessionPane | null} */
let current = null;

/** @returns {SessionPane | null} */
export function currentPane() {
  return current;
}

/** @returns {Session | null} */
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

// The current session's entry with the live activity, or null with no open session.
/** @returns {FeedItem | null} */
export function currentEntry() {
  const id = current?.session.sessionId;
  if (!id) return null;
  const item = feedItem(id);
  if (!item) return null;
  const activity = current?.session.activity;
  return activity ? { session: item.session, activity } : item;
}

// Load the catalog, then pick a model and its effort. A `query` names the model and skips the picker.
/** @param {InjectContext} ctx @param {string} [query] */
function openModelPicker(ctx, query) {
  const pane = current;
  if (!pane) return null;
  const entry = currentEntry();
  const currentId = entry ? entry.session.model : null;
  const show = () => {
    // Code-unit order: localeCompare NFC-normalizes and traps in ReleaseSafe QuickJS.
    const models = catalogOf().models.slice().sort((a, b) => (a.provider < b.provider ? -1 : a.provider > b.provider ? 1 : 0) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    if (models.length === 0) return notice.show("no model in the catalog");
    if (query) {
      const m = models.find((x) => x.selector === query || x.id === query || x.name === query);
      if (m) {
        if (modelAvailable(m)) pane.session.setModel(m, m.default_reasoning || m.reasoning_levels[0] || "");
      }
      else notice.show("no model named " + query);
      return;
    }
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "none",
      panelGroup: "UIFloat",
      anchor: pane.composer ? () => /** @type {Composer} */ (pane.composer).rect : null,
      maxRows: 6,
      items: models,
      // The catalog owns the selector format. The picker keys on it and never builds one.
      key: (m) => m.selector,
      filterText: m => m.provider + " " + m.name + " " + m.id,
      // A model with a provider that cannot serve shows the reason before the user starts a run.
      format: m => {
        const label = providerStateLabel(providerState(m.provider));
        return label ? { text: m.name, right: m.provider + " · " + label, group: "UIDim" } : { text: m.name, right: m.provider };
      },
      onAccept: m => {
        if (modelAvailable(m)) pickReasoning(ctx, m, pane.session);
      },
    });
    ctx.tui.overlay(p.win);
    p.content.list.selectKey(currentId);
  };
  // Reload the file before the picker lists, so a login from another process shows.
  reloadCatalog().then(show);
  return null;
}

/** @param {Wire.ModelInfo} model @returns {boolean} */
function modelAvailable(model) {
  const state = providerState(model.provider);
  if (state === "needs_credential") command.perform("auth:login", model.provider);
  else if (state === "needs_route") notice.show(model.provider + " needs a route in providers.json");
  else return true;
  return false;
}

// A model with at most one level needs no second step, so the pick ends there.
/** @param {InjectContext} ctx @param {Wire.ModelInfo} model @param {Session} session @returns {void} */
function pickReasoning(ctx, model, session) {
  const levels = model.reasoning_levels;
  if (levels.length < 2) {
    session.setModel(model, model.default_reasoning || levels[0] || "");
    return;
  }
  const composer = current?.composer;
  const step = ui.pick({
    title: model.name + " · effort",
    footer: "↵ select · esc close",
    border: "none",
    panelGroup: "UIFloat",
    anchor: composer ? () => composer.rect : null,
    maxRows: 6,
    items: levels.map((id) => ({ id })),
    key: l => l.id,
    filterText: l => l.id,
    format: l => ({ text: l.id }),
    onAccept: l => session.setModel(model, l.id),
  });
  ctx.tui.overlay(step.win);
  step.content.list.selectKey(model.default_reasoning || levels[0]);
}

// A session finder reads the sessions, fuzzy-searches them by title, then opens one in the current pane.
/** @param {InjectContext} ctx @returns {void} */
function openSessionFinder(ctx) {
  feed.refresh().then(() => {
    const rows = feed.rows().filter((row) => row.session.origin.type !== "child").sort((a, b) => (b.session.updated_at_ms || 0) - (a.session.updated_at_ms || 0));
    if (rows.length === 0) {
      notice.show("no sessions yet");
      return;
    }
    const p = ui.pick({
      title: "sessions",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: max => Math.round(max * 0.6),
      height: max => Math.round(max * 0.5),
      items: rows,
      key: r => r.id,
      filterText: r => r.title,
      // An open session reads its live activity; the rest shows what the list reported. A working session shows "●".
      format: r => ({ text: r.title, right: (sessionOf(r.id)?.activity || r.activity).state.type === "idle" ? "" : "●" }),
      onAccept: r => {
        if (current) openSession(current, r.id);
      },
    });
    ctx.tui.overlay(p.win);
  });
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
      ctx.effect(() => () => {
        current = null;
        notifyCurrent();
      });

      // Views on one session share it, so the event reaches that session once and it updates every view.
      // The digest names the activity fact and the session reads the projection, so a burst costs one read per frame.
      ctx.on("session.changed", (ev) => {
        for (const session of sessions) {
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

      // A summary fact reaches the index because its payload names no session id; an overflow drops facts.
      // Either one makes the list stale. A catalog, notice, or login fact leaves it alone.
      ctx.on("index.changed", (ev) => {
        if (ev.overflow || ev.facts.indexOf("session.summary_changed") >= 0) feed.changes++;
      });

      // The model the current session sends to, on the right of the status bar.
      ctx.tui.status.add({
        side: "right",
        order: 10,
        render: () => {
          const e = currentEntry();
          if (e && e.session.model) return e.session.model;
          return defaultModel().model || "";
        },
      });

      ctx.tui.command.add("session:interrupt", { when: () => current?.session.sessionId != null, desc: "stop the run", slash: true, run: () => current?.session.interrupt() });
      ctx.tui.command.add("ui:sessions", { desc: "open a session", slash: true, run: () => openSessionFinder(ctx) });
      ctx.tui.command.add("model:pick", { desc: "choose the model for the next chat", slash: "model", args: true, run: (/** @type {string | undefined} */ query) => openModelPicker(ctx, query) });
      ctx.tui.command.add("context:reload", {
        desc: "rescan AGENTS.md and skills for this chat",
        slash: true,
        run: () => {
          const id = current?.session.sessionId;
          if (!id) return notice.show("no open chat");
          client.sessionReloadContext(id).then((r) => {
            notice.show("Context reloaded: " + r.instruction_sources.length + " AGENTS.md, " + r.skills.length + " skills.");
            root.invalidate();
          }).catch((e) => {
            notice.show("Context reload failed: " + errorText(e));
          });
        },
      });
      ctx.tui.command.add("context:compact", {
        desc: "summarize the earlier history of this chat",
        slash: true,
        run: () => {
          const id = current?.session.sessionId;
          if (!id) return notice.show("no open chat");
          client.sessionCompact(id).then((r) => {
            notice.show(r.status === "started" ? "Compacting the context." : "Compaction waits for the active run.");
            root.invalidate();
          }).catch((e) => {
            notice.show("Compaction failed: " + errorText(e));
          });
        },
      });
      ctx.tui.keymap.add({ "ctrl+f": "ui:sessions", "ctrl+c": "session:interrupt" });
    });
  },
};
