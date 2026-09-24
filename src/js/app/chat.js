// yuke:chat — the chat pane, the session it drives, and the pickers that read its transcript.
import { root, copy, command } from "yuke:core";
import { config, events } from "yuke:kernel";
import { term } from "yuke:term";
import { ui, Text } from "yuke:ui";
import { column, child, fixed, grow } from "yuke:layout";
import { ChatView } from "yuke:chat-view";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { feedItem } from "yuke:sessions";
import { activityOf, refreshActivity } from "yuke:activity";
import { catalogOf, modelOf, reloadCatalog, chooseModel, defaultModel, providerState, providerStateLabel } from "yuke:catalog";
import { pasteAttaches } from "yuke:attach";
import { errorText } from "yuke:format";

/** @import { PresentationContext } from "yuke:chat-view" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Context } from "yuke:ext" */
/** @import { EngineEvent } from "yuke:engine-native" */
/** @typedef {Extract<EngineEvent, { type: "session" }>} NativeSessionEvent */
/** @typedef {Wire.CreateSession} CreateSessionDraft */
/** @import { FeedItem } from "yuke:sessions" */

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

/** @param {{ name: string, args: string }} invocation @returns {Wire.Input} */
function skillInput(invocation) {
  return { type: "skill", name: invocation.name, ...(invocation.args ? { arguments: invocation.args } : {}) };
}

// One chat pane and the session it drives. Each pane owns its own view, transcript and session.
export class Chat {
  constructor() {
    // Use open or newChat to change the session and its native pin.
    /** @type {string | null} */
    this.sessionId = null;
    this.creating = false;
    this.gen = 0;
    this.view = new ChatView({
      partsOf: id => (this.sessionId ? client.sessionParts(this.sessionId, id) : []),
      partOf: (id, partId, previous) => (this.sessionId ? client.sessionPart(this.sessionId, id, partId, previous) : null),
      partTextPage: (id, partId, field, offset, limit) => (this.sessionId ? client.partTextPage(this.sessionId, id, partId, field, offset, limit) : { text: "", next: null }),
      onSubmit: content => this.send(content),
      onSelect: text => {
        if (config.mouse.copyOnSelect) copy(text, "selection");
      },
      sessionId: () => this.sessionId,
    });
    // A pasted image path attaches here instead of staying text; every other paste keeps its old behavior.
    this.composer.onPaste = (text, from) => pasteAttaches(this.composer, text, from);
    CHAT_OF.set(this.view, this);
    chats.add(this);
  }

  get transcript() {
    return this.view.transcript;
  }

  get composer() {
    return this.view.composer;
  }

  // Open a session in this pane. The engine counts the pins, so one open owes exactly one close.
  /** @param {string} id */
  open(id) {
    if (this.sessionId === id) return this.reload(); // already pinned by this pane
    // A second pane on one session must not lose it, so a later open cannot reuse a stale creation.
    this.gen++;
    this.creating = false;
    if (!client.sessionOpen(id)) {
      notice.show("open failed · session unavailable");
      root.invalidate();
      return;
    }
    if (this.sessionId) this.release();
    this.sessionId = id;
    refreshActivity(id);
    // Message ids repeat across sessions, so the old render must go before the new outline lands.
    this.transcript.setOutline([], null);
    this.reload();
    this.checkContext(id);
    notifyFocusedSession();
  }

  // Tell the user once per open when the files behind the stored snapshots changed. The user decides on /reload.
  /** @param {string} id */
  checkContext(id) {
    const token = this.gen;
    client.sessionCheckContext(id).then((item) => {
      // A later open or new chat moves the generation, so a slow answer for an earlier open stays silent.
      if (token !== this.gen || this.sessionId !== id) return;
      const changes = item.context_changes;
      if (!changes || (!changes.instructions && !changes.skills)) return;
      const what = changes.instructions && changes.skills ? "AGENTS.md and skills" : changes.instructions ? "AGENTS.md" : "skills";
      notice.show(what + " changed on disk. Run /reload to update this session.");
      root.invalidate();
    }).catch(() => {});
  }

  // Send composer content into the open session, or return false so the composer keeps it.
  /** @param {readonly Wire.ContentPart[]} content @returns {boolean} */
  send(content) {
    const text = soleText(content);
    const invocation = text === null ? null : parseSkillLine(text);
    if (!this.sessionId) return this.startChat(invocation ? skillInput(invocation) : { type: "content", content });
    const snap = this.composer.snapshot();
    const sent = invocation ? client.sessionSendSkill(this.sessionId, invocation.name, invocation.args) : client.sessionSendInput(this.sessionId, content);
    sent.catch((e) => {
      this.composer.restore(snap);
      notice.show("send failed · " + errorText(e));
    });
    return true;
  }

  // The model this chat's next input goes to: the open session's own, or the default a new chat takes.
  /** @returns {string} */
  modelSelector() {
    const item = this.sessionId ? feedItem(this.sessionId) : null;
    return (item && item.session.model) || defaultModel().model || "";
  }

  // Warn when the images now in the composer will not reach the model the next input goes to.
  /** @param {string} [selector] @returns {void} */
  checkVision(selector = this.modelSelector()) {
    if (!this.composer.hasImages()) return;
    const model = selector === "" ? null : modelOf(selector);
    // An unknown model, and one whose catalog entry says nothing, never raise a warning.
    if (!model || model.supports_vision !== false) return;
    notice.show(model.name + " reads no images");
    root.invalidate();
  }

  // Stop the run and keep the queue, so an interrupt never drops a message the user already typed.
  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.sessionId).catch(() => {});
  }

  // Re-pull the outline on a structural change; a closed session must not empty the pane.
  reload() {
    if (!this.sessionId) return;
    const o = client.sessionOutline(this.sessionId);
    if (!o || !Array.isArray(o.messages)) return;
    this.transcript.setOutline(o.messages, o.active || null);
    root.invalidate();
  }

  // A draft delta: re-wrap only the streaming message `id`, or only its part `partId` when the digest names one.
  /** @param {number} id @param {number} [partId] */
  active(id, partId) {
    this.transcript.setActive(id, partId);
    root.invalidate();
  }

  // Accept the session and first input together, then open the accepted session. The composer takes the input back on failure.
  /** @param {Wire.Input} input @returns {boolean} */
  startChat(input) {
    if (this.creating) return false;
    if (!term.cwd) {
      notice.show("no workspace directory");
      return false;
    }
    const snap = this.composer.snapshot();
    const d = defaultModel();
    const params = /** @type {CreateSessionDraft} */ ({ workspace_path: term.cwd, ...(d.model ? { model: d.model } : {}), ...(d.reasoning ? { reasoning: d.reasoning } : {}), initial_input: input });
    const token = ++this.gen;
    this.creating = true;
    client
      .sessionCreate(params)
      .then((r) => {
        // Navigation changes the pane; accepted work still belongs to the new session.
        if (token !== this.gen) return null;
        this.open(r.session.id);
        return null;
      })
      .catch((e) => {
        // A cancelled create must not restore an input into a pane the user already moved on from.
        if (token !== this.gen) return;
        this.composer.restore(snap);
        notice.show("new chat failed · " + errorText(e));
      })
      .then(() => {
        if (token === this.gen) this.creating = false;
      });
    return true;
  }

  // Leave the open session and show an empty pane; the engine creates a session on the next message.
  newChat() {
    this.gen++;
    this.creating = false;
    this.release();
    this.sessionId = null;
    this.transcript.setOutline([], null);
    root.focusView(this.view);
    root.invalidate();
    notifyFocusedSession();
  }

  // The engine lost the session. Clear the pane back to the placeholder.
  sessionGone() {
    this.sessionId = null;
    this.transcript.setOutline([], null);
    root.invalidate();
    notifyFocusedSession();
  }

  // Drop this pane's pin. The engine counts pins, so a second pane on the same session keeps it.
  release() {
    if (!this.sessionId) return;
    const id = this.sessionId;
    client.sessionClose(id);
    // The read keeps the activity while the runtime works and drops it after an eviction.
    refreshActivity(id);
  }

  // The pane left the tree, so the session goes and the chat leaves the registry.
  dispose() {
    this.view.clearPresentation();
    this.gen++;
    this.creating = false;
    this.release();
    this.sessionId = null;
    chats.delete(this);
    CHAT_OF.delete(this.view);
    notifyFocusedSession();
  }
}

// Every live chat pane, so an event reaches each pane that shows the session it names.
/** @type {Set<Chat>} */
export const chats = new Set();

// The Chat that owns a view, so a pane in the tree leads back to its session.
/** @type {WeakMap<object, Chat>} */
const CHAT_OF = new WeakMap();

/** @param {unknown} view @returns {Chat | null} */
export function chatOf(view) {
  if (!view) return null;
  return CHAT_OF.get(/** @type {object} */ (view)) || null;
}

// Overlays retain the active pane; a non-chat pane has no focused session.
/** @returns {string | null} */
export function focusedSessionId() {
  return chatOf(root.active)?.sessionId ?? null;
}

events.declare(["session.focused"]);
/** @type {string | null} */
let lastFocusedSession = null;

function notifyFocusedSession() {
  const id = focusedSessionId();
  if (id === lastFocusedSession) return;
  lastFocusedSession = id;
  events.emit("session.focused");
}

events.on("pane.focused", notifyFocusedSession);
events.on("pane.closed", notifyFocusedSession);

// The focused view that `match` accepts, or the first one in the tree.
/** @param {(v: any) => boolean} match @returns {any} */
function focusedLeaf(match) {
  const v = root.active;
  if (v && match(v)) return v;
  const rn = root.root_node;
  if (!rn) return null;
  for (const leaf of rn.leaves()) if (leaf.shape.type === "leaf" && match(leaf.shape.view)) return leaf.shape.view;
  return null;
}

// The chat pane a layer drives. A bare ChatView counts, because a layer reads the view alone.
/** @returns {ChatView | null} */
export function focusedChatView() {
  return focusedLeaf(v => v.name === "chat");
}

// The chat a session command acts on. Only a pane this module built owns a session.
/** @returns {Chat | null} */
export function focusedChat() {
  return chatOf(focusedLeaf(v => CHAT_OF.has(v)));
}

// The focused chat's entry with the live activity, or null with no open session.
/** @returns {FeedItem | null} */
export function chatEntry() {
  const c = focusedChat();
  if (!c || !c.sessionId) return null;
  const item = feedItem(c.sessionId);
  if (!item) return null;
  const activity = activityOf(c.sessionId);
  return activity ? { session: item.session, activity } : item;
}

// Load the catalog, then pick a model and its effort. A `query` names the model and skips the picker.
/** @param {InjectContext} ctx @param {string} [query] */
function openModelPicker(ctx, query) {
  const chat = focusedChat();
  if (!chat) return null;
  const current = chatEntry();
  const currentId = current && current.session ? current.session.model : null;
  const show = () => {
    // Code-unit order: localeCompare NFC-normalizes and traps in ReleaseSafe QuickJS.
    const models = catalogOf().models.slice().sort((a, b) => (a.provider < b.provider ? -1 : a.provider > b.provider ? 1 : 0) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    if (models.length === 0) {
      notice.show("no model in the catalog");
      return null;
    }
    if (query) {
      const m = models.find((x) => x.selector === query || x.id === query || x.name === query);
      if (m) {
        if (modelAvailable(m)) chooseModel(m, m.default_reasoning || m.reasoning_levels[0] || "", chat.sessionId);
      }
      else notice.show("no model named " + query);
      return null;
    }
    // The catalog owns the selector format. The picker keys on it and never builds one.
    /** @param {Wire.ModelInfo} m @returns {string} */
    const qualified = (m) => m.selector;
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "none",
      panelGroup: "UIFloat",
      anchor: () => chat.composer.rect,
      maxRows: 6,
      items: models,
      key: qualified,
      filterText: m => m.provider + " " + m.name + " " + m.id,
      // A model with a provider that cannot serve shows the reason before the user starts a run.
      format: m => {
        const label = providerStateLabel(providerState(m.provider));
        return label ? { text: m.name, right: m.provider + " · " + label, group: "UIDim" } : { text: m.name, right: m.provider };
      },
      onAccept: m => {
        if (modelAvailable(m)) pickReasoning(ctx, m, chat.sessionId);
      },
    });
    ctx.tui.overlay(p.win);
    p.content.list.selectKey(currentId);
    return p;
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
  const chat = focusedChat();
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
      ctx.on("composer.attached", () => { for (const c of chats) c.checkVision(); });
      // The feed reads the patch back later, so a pane on the patched session checks the new model directly.
      ctx.on("model.changed", /** @param {{ model: Wire.ModelInfo, sessionId: string | null }} ev */ (ev) => {
        for (const c of chats) c.checkVision(ev.sessionId !== null && c.sessionId === ev.sessionId ? ev.model.selector : c.modelSelector());
      });

      // Two panes can show one session, so the event reaches every pane that names it.
      ctx.on("session.changed", /** @param {NativeSessionEvent} ev */ (ev => {
        // A quiet digest changes only state outside the transcript.
        if (!ev || ev.kind === "quiet") return;
        for (const c of chats) {
          if (c.sessionId !== ev.session) continue;
          if (ev.kind === "gone") c.sessionGone();
          else if (ev.kind === "active") c.active(/** @type {number} */ (ev.id), ev.part);
          else c.reload();
        }
      }));


      // A closed pane must drop its pin, or the engine never evicts the session.
      ctx.on("pane.closed", view => {
        const c = chatOf(view);
        if (c) c.dispose();
      });

      ctx.tui.command(null, {
        "model:pick": (/** @type {string | undefined} */ query) => openModelPicker(ctx, query),
        "context:reload": () => {
          const c = focusedChat();
          if (!c || !c.sessionId) return notice.show("no open chat");
          client.sessionReloadContext(c.sessionId).then((r) => {
            notice.show("Context reloaded: " + r.instruction_sources.length + " AGENTS.md, " + r.skills.length + " skills.");
            root.invalidate();
          }).catch((e) => {
            notice.show("Context reload failed: " + errorText(e));
          });
        },
        "context:compact": () => {
          const c = focusedChat();
          if (!c || !c.sessionId) return notice.show("no open chat");
          client.sessionCompact(c.sessionId).then((r) => {
            notice.show(r.status === "started" ? "Compacting the context." : "Compaction waits for the active run.");
            root.invalidate();
          }).catch((e) => {
            notice.show("Compaction failed: " + errorText(e));
          });
        },
      }, {
        "model:pick": { title: "Model", description: "choose the model for the next chat", slash: "model", args: true },
        "context:reload": { title: "Reload context", description: "rescan AGENTS.md and skills for this chat", slash: "reload" },
        "context:compact": { title: "Compact context", description: "summarize the earlier history of this chat", slash: "compact" },
      });
      });
},
};
