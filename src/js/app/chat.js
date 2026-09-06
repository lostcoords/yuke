// yuke:chat — the chat pane, the session it drives, and the pickers that read its transcript.
import { root, config, copy, command } from "yuke:core";
import { term } from "yuke:term";
import { ui } from "yuke:ui";
import { ChatView } from "yuke:transcript";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { feedItem } from "yuke:sessions";
import { activityOf, refreshActivity } from "yuke:activity";
import { catalogOf, reloadCatalog, chooseModel, defaultModel, providerState, providerStateLabel } from "yuke:catalog";


/** @typedef {Extract<import("yuke:engine-native").EngineEvent, { type: "session" }>} NativeSessionEvent */
/** @typedef {{ workspace_path: string, profile?: string, model?: string, reasoning?: string, system_prompt?: string, max_rounds?: number }} CreateSessionDraft */
/** @typedef {import("yuke:sessions").FeedItem} FeedItem */

const newChatLines = () => {
  const m = defaultModel().model;
  return [
    { text: "new chat", group: "YukeBrand" },
    { text: m ? "model · " + m : "no model yet", group: "YukeEmpty" },
    { text: "type a message to start the session", group: "YukeEmpty" },
  ];
};

// One chat pane and the session it drives. Each pane owns its own view, transcript and session.
export class Chat {
  constructor() {
    /** @type {string | null} */
    this.sessionId = null;
    this.creating = false;
    this.gen = 0;
    this.view = new ChatView({
      textOf: id => (this.sessionId ? client.sessionText(this.sessionId, id) : ""),
      partsOf: id => (this.sessionId ? client.sessionParts(this.sessionId, id) : []),
      partOf: (id, partId) => (this.sessionId ? client.sessionPart(this.sessionId, id, partId) : null),
      onSubmit: text => this.send(text),
      onSelect: text => {
        if (config.mouse.copyOnSelect) copy(text, "selection");
      },
      empty: () => (this.sessionId ? null : newChatLines()),
    });
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
    if (this.sessionId) this.release();
    // A second pane on one session must not lose it, so a later open cannot reuse a stale creation.
    this.gen++;
    this.creating = false;
    this.sessionId = id;
    client.sessionOpen(id);
    refreshActivity(id);
    // Message ids repeat across sessions, so the old render must go before the new outline lands.
    this.transcript.setOutline([], null);
    this.reload();
  }

  // Send composer text into the open session, or return false so the composer keeps the text.
  /** @param {string} text @returns {boolean} */
  send(text) {
    if (!this.sessionId) return this.startChat(text);
    client.sessionSendInput(this.sessionId, text).catch((e) => {
      this.restoreInput(text);
      notice.show("send failed · " + ((e && e.message) || "unknown"));
      root.invalidate();
    });
    return true;
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

  // Create the session, open it, then send the first message; the engine makes a session on demand.
  /** @param {string} text @returns {boolean} */
  startChat(text) {
    if (this.creating) return false;
    if (!term.cwd) {
      notice.show("no workspace directory");
      return false;
    }
    const d = defaultModel();
    const params = /** @type {CreateSessionDraft} */ ({ workspace_path: term.cwd });
    if (d.model) params.model = d.model;
    if (d.reasoning) params.reasoning = d.reasoning;
    const token = ++this.gen;
    this.creating = true;
    client
      .sessionCreate(params)
      .then((r) => {
        // A cancelled create drops its pin, but the protocol has no delete, so the empty session stays.
        if (token !== this.gen) {
          client.sessionClose(r.session.id);
          return null;
        }
        // `open` moves the token, so the first message takes the plain send path and its own failure notice.
        this.open(r.session.id);
        this.send(text);
        return null;
      })
      .catch((e) => {
        // A cancelled create must not restore text into a pane the user already moved on from.
        if (token !== this.gen) return;
        this.restoreInput(text);
        notice.show("new chat failed · " + ((e && e.message) || "unknown"));
        root.invalidate();
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
  }

  // The engine lost the session. Clear the pane back to the placeholder.
  sessionGone() {
    this.sessionId = null;
    this.transcript.setOutline([], null);
    root.invalidate();
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
    this.gen++;
    this.creating = false;
    this.release();
    this.sessionId = null;
    chats.delete(this);
  }

  /** @param {string} text @returns {void} */
  restoreInput(text) {
    const now = this.composer.text;
    this.composer.text = now === "" ? text : text + "\n" + now;
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

// The focused view that `match` accepts, or the first one in the tree.
/** @param {(v: any) => boolean} match @returns {any} */
function focusedLeaf(match) {
  const v = root.active;
  if (v && match(v)) return v;
  const rn = root.root_node;
  if (!rn) return null;
  for (const leaf of rn.leaves()) if (leaf.view && match(leaf.view)) return leaf.view;
  return null;
}

// The chat pane a layer drives. A bare ChatView counts, because a layer reads the view alone.
/** @returns {import("yuke:transcript").ChatView | null} */
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
/** @param {import("yuke:ext").InjectContext} ctx @param {string} [query] */
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
      if (m) chooseModel(m, m.default_reasoning || m.reasoning_levels[0] || "");
      else notice.show("no model named " + query);
      return null;
    }
    // The catalog owns the selector format. The picker keys on it and never builds one.
    /** @param {Wire.ModelInfo} m @returns {string} */
    const qualified = (m) => m.selector;
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: 0.6,
      height: 0.6,
      items: models,
      key: qualified,
      filterText: m => m.provider + " " + m.name + " " + m.id,
      // A model with a provider that cannot serve shows the reason before the user starts a run.
      format: m => {
        const label = providerStateLabel(providerState(m.provider));
        return label ? { text: m.name, right: m.provider + " · " + label, group: "UIDim" } : { text: m.name, right: m.provider };
      },
      onAccept: m => {
        const state = providerState(m.provider);
        if (state === "needs_credential" || state === "expired") command.perform("auth:login", m.provider);
        else if (state === "needs_route") notice.show(m.provider + " needs a route in providers.json");
        else pickReasoning(ctx, m);
      },
    });
    ctx.tui.overlay(p.win);
    p.content.selectKey(currentId);
    return p;
  };
  // Reload the file before the picker lists, so a login from another process shows.
  reloadCatalog().then(show);
  return null;
}

// A model with one level needs no second step, so the pick ends there.
/** @param {import("yuke:ext").InjectContext} ctx @param {Wire.ModelInfo} model @returns {void} */
function pickReasoning(ctx, model) {
  const levels = model.reasoning_levels;
  if (levels.length < 2) {
    chooseModel(model, model.default_reasoning || levels[0] || "");
    return;
  }
  const step = ui.pick({
    title: model.name + " · effort",
    footer: "↵ select · esc close",
    border: "rounded",
    width: 0.4,
    height: 0.4,
    items: levels.map((id) => ({ id })),
    key: l => l.id,
    filterText: l => l.id,
    format: l => ({ text: l.id }),
    onAccept: l => chooseModel(model, l.id),
  });
  ctx.tui.overlay(step.win);
  step.content.selectKey(model.default_reasoning || levels[0]);
}

// The chat's own listeners and the model command.
export const chatPlugin = {
  name: "chat",
  /** @param {import("yuke:ext").InjectContext} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
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
      }, {
        "model:pick": { title: "Model", description: "choose the model for the next chat", slash: "model", args: true },
      });
      });
},
};
