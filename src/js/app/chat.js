// The chat pane, the session it drives, and the pickers that read its transcript.
import { root, command } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { term } from "yuke:internal/native/term";
import { ui, Text } from "yuke:internal/ui";
import { column, child, fixed, grow } from "yuke:internal/layout";
import { client } from "yuke:internal/client";
import { notice } from "yuke:internal/notice";
import { feedItem } from "yuke:internal/sessions";
import { activityOf, refreshActivity } from "yuke:internal/activity";
import { catalogOf, modelOf, reloadCatalog, chooseModel, defaultModel, providerState, providerStateLabel } from "yuke:internal/catalog";
import { errorText } from "yuke:internal/format";

/** @import { ChatView, PresentationContext } from "yuke:internal/chat-view" */
/** @import { Composer } from "yuke:internal/ui" */
/** @import { MessagePart } from "yuke:internal/native/engine" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Context } from "yuke:internal/ext" */
/** @typedef {Wire.CreateSession} CreateSessionDraft */
/** @import { FeedItem } from "yuke:internal/sessions" */

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
    /** @type {Set<ChatView>} */
    this.views = new Set();
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
    refreshActivity(id);
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

  // Stop the run and keep the queue, so an interrupt never drops a message the user already typed.
  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.sessionId).catch(() => {});
  }

  // Re-pull the outline into `views` on a structural change; a closed session must not empty them.
  /** @param {Iterable<ChatView>} [views] */
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
    this.sessionId = null;
    for (const view of this.views) view.transcript.setOutline([], null);
    root.invalidate();
    notifyCurrent();
  }

  // Drop the pin. The engine counts pins, so an unrelated open of the same id elsewhere keeps it.
  release() {
    if (!this.sessionId) return;
    const id = this.sessionId;
    client.sessionClose(id);
    // The read keeps the activity while the runtime works and drops it after an eviction.
    refreshActivity(id);
  }

  // A view stops showing this session. The last view releases the pin and takes the session out of the registry.
  /** @param {ChatView} view */
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

// A chat pane is a view that shows a session. A custom view joins by holding one.
/** @param {unknown} view @returns {view is ChatView} */
function isChat(view) {
  return /** @type {{ session?: unknown } | null} */ (view)?.session instanceof Session;
}

// Show `session` in `view`. The old session leaves, and its last view releases it.
/** @param {ChatView} view @param {Session} session @returns {void} */
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
/** @param {ChatView} view @param {string} id @returns {void} */
export function openSession(view, id) {
  for (const held of sessions) {
    if (held.sessionId === id) return showSession(view, held);
  }
  const session = new Session();
  if (session.open(id)) showSession(view, session);
  else sessions.delete(session);
}

// Warn when the images in a view's composer will not reach the model its next input goes to.
/** @param {ChatView} view @param {string} [selector] @returns {void} */
function checkVision(view, selector = view.session.modelSelector()) {
  if (!view.composer.hasImages()) return;
  const model = selector === "" ? null : modelOf(selector);
  // An unknown model, and one whose catalog entry says nothing, never raise a warning.
  if (!model || model.supports_vision !== false) return;
  notice.show(model.name + " reads no images");
  root.invalidate();
}

// The current chat: the chat pane that had focus last and is still in the tree. Session commands, the status bar,
// and `chat.current.changed` all read it, so a focused pane that is not a chat, such as a panel, leaves it in place.
/** @type {ChatView | null} */
let current = null;

/** @returns {ChatView | null} */
export function currentChat() {
  return current;
}

events.declare(["chat.current.changed"]);
/** @type {string | null} */
let announced = null;

// Announce a change of the current session once, so a repeat open of the same session stays quiet.
function notifyCurrent() {
  const id = current?.session.sessionId ?? null;
  if (id === announced) return;
  announced = id;
  events.emit("chat.current.changed");
}

events.on("pane.focused", (view) => {
  if (!isChat(view)) return;
  current = view;
  notifyCurrent();
});

// A closed current chat hands over to the focused chat, else to the first chat left in the tree.
events.on("pane.closed", (view) => {
  if (current && current !== view) return;
  current = null;
  const candidates = root.root_node ? [root.active, ...root.root_node.leaves().map((leaf) => (leaf.shape.type === "leaf" ? leaf.shape.view : null))] : [];
  for (const candidate of candidates) {
    if (!isChat(candidate)) continue;
    current = candidate;
    break;
  }
  notifyCurrent();
});

// The current chat's entry with the live activity, or null with no open session.
/** @returns {FeedItem | null} */
export function chatEntry() {
  const id = current?.session.sessionId;
  if (!id) return null;
  const item = feedItem(id);
  if (!item) return null;
  const activity = activityOf(id);
  return activity ? { session: item.session, activity } : item;
}

// Load the catalog, then pick a model and its effort. A `query` names the model and skips the picker.
/** @param {InjectContext} ctx @param {string} [query] */
function openModelPicker(ctx, query) {
  const chat = current;
  if (!chat) return null;
  const entry = chatEntry();
  const currentId = entry ? entry.session.model : null;
  const show = () => {
    // Code-unit order: localeCompare NFC-normalizes and traps in ReleaseSafe QuickJS.
    const models = catalogOf().models.slice().sort((a, b) => (a.provider < b.provider ? -1 : a.provider > b.provider ? 1 : 0) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    if (models.length === 0) return notice.show("no model in the catalog");
    if (query) {
      const m = models.find((x) => x.selector === query || x.id === query || x.name === query);
      if (m) {
        if (modelAvailable(m)) chooseModel(m, m.default_reasoning || m.reasoning_levels[0] || "", chat.session.sessionId);
      }
      else notice.show("no model named " + query);
      return;
    }
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "none",
      panelGroup: "UIFloat",
      anchor: () => chat.composer.rect,
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
        if (modelAvailable(m)) pickReasoning(ctx, m, chat.session.sessionId);
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
/** @param {InjectContext} ctx @param {Wire.ModelInfo} model @param {string | null} sessionId @returns {void} */
function pickReasoning(ctx, model, sessionId) {
  const levels = model.reasoning_levels;
  if (levels.length < 2) {
    chooseModel(model, model.default_reasoning || levels[0] || "", sessionId);
    return;
  }
  const chat = current;
  const step = ui.pick({
    title: model.name + " · effort",
    footer: "↵ select · esc close",
    border: "none",
    panelGroup: "UIFloat",
    anchor: chat ? () => chat.composer.rect : null,
    maxRows: 6,
    items: levels.map((id) => ({ id })),
    key: l => l.id,
    filterText: l => l.id,
    format: l => ({ text: l.id }),
    onAccept: l => chooseModel(model, l.id, sessionId),
  });
  ctx.tui.overlay(step.win);
  step.content.list.selectKey(model.default_reasoning || levels[0]);
}

// The chat's own listeners and the model command.
export const chatPlugin = {
  name: "chat",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.presentation(() => {
        const title = new Text({ text: "new chat", group: "YukeBrand" });
        const hint = new Text({ group: "YukeEmpty" });
        return (/** @type {PresentationContext} */ { empty, sessionId, defaultLayout }) => {
          if (!empty || sessionId) return defaultLayout;
          const model = defaultModel().model;
          hint.setText((model ? "model · " + model : "no model yet") + "\ntype a message to start the session");
          return column(defaultLayout.children.map(item => item.value === "transcript"
            ? child(null, grow(), { layout: column([child(title, fixed(1)), child(hint, grow())], { padding: { left: 2 } }) }) : item));
        };
      });
      // The composer owns its own attachments, so each pane answers for the model it sends to.
      ctx.on("composer.attached", () => { for (const session of sessions) for (const view of session.views) checkVision(view); });
      // The feed reads the patch back later, so a pane on the patched session checks the new model directly.
      ctx.on("model.changed", (ev) => {
        for (const session of sessions) {
          const selector = ev.sessionId !== null && session.sessionId === ev.sessionId ? ev.model.selector : session.modelSelector();
          for (const view of session.views) checkVision(view, selector);
        }
      });

      // Views on one session share it, so the event reaches that session once and it updates every view.
      ctx.on("session.changed", (ev) => {
        // A quiet digest changes only state outside the transcript.
        if (ev.kind === "quiet") return;
        for (const session of sessions) {
          if (session.sessionId !== ev.session) continue;
          if (ev.kind === "gone") session.sessionGone();
          else if (ev.kind === "active") session.active(/** @type {number} */ (ev.id), ev.part);
          else session.reload();
        }
      });

      // A closed pane leaves its session, and the last view releases the pin, or the engine never evicts it.
      ctx.on("pane.closed", (view) => {
        if (!isChat(view)) return;
        view.clearPresentation();
        view.session.leave(view);
      });

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
      });
},
};
