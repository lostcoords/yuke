// yuke:chat — the chat pane, the session it drives, and the pickers that read its transcript.
import { root, config, copy, events } from "yuke:core";
import { term } from "yuke:term";
import { ui } from "yuke:ui";
import { ChatView } from "yuke:transcript";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { feedItem } from "yuke:sidebar";
import { catalogOf, loadCatalog, chooseModel, defaultModel } from "yuke:catalog";

const LOCAL = client.LOCAL;

/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "session" }>} NativeSessionEvent */
/** @typedef {Extract<import("yuke:client-native").ClientEvent, { type: "conn" }> & { workspaces?: readonly Wire.Workspace[] }} NativeConnEvent */
/** @typedef {{ workspace_path?: string, profile?: string, model?: string, reasoning?: string, system_prompt?: string, permission?: Wire.PermissionMode, max_rounds?: number }} CreateSessionDraft */
/** @typedef {import("yuke:sidebar").FeedItem} FeedItem */

const newChatLines = () => {
  const m = defaultModel().model;
  return [
    { text: "new chat", group: "YukeBrand" },
    { text: m ? "model · " + m : "no model yet · :model:pick", group: "YukeEmpty" },
    { text: "type a message to start the session", group: "YukeEmpty" },
  ];
};

// One chat pane and the session it drives. Each pane owns its own view, transcript and session.
export class Chat {
  constructor() {
    this.connKey = LOCAL;
    /** @type {string | null} */
    this.sessionId = null;
    this.creating = false;
    this.gen = 0;
    this.view = new ChatView({
      textOf: id => (this.sessionId ? client.sessionText(this.connKey, this.sessionId, id) : ""),
      partsOf: id => (this.sessionId ? client.sessionParts(this.connKey, this.sessionId, id) : []),
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

  /** @param {string} connKey @param {string | null | undefined} id */
  open(connKey, id) {
    if (id == null) {
      id = connKey;
      connKey = LOCAL;
    }
    if (this.sessionId && (this.connKey !== connKey || this.sessionId !== id)) this.release();
    // A second pane on one session must not lose it, so a later open cannot reuse a stale creation.
    this.gen++;
    this.creating = false;
    this.connKey = connKey;
    this.sessionId = id;
    client.sessionOpen(this.connKey, id);
    client.sessionResync(this.connKey, id).catch(() => {});
    this.reload();
  }

  // Send composer text into the open session, or return false so the composer keeps the text.
  /** @param {string} text @returns {boolean} */
  send(text) {
    if (!this.sessionId) return this.startChat(text);
    client.sessionSendInput(this.connKey, this.sessionId, text).catch((e) => {
      this.restoreInput(text);
      notice.show("send failed · " + ((e && e.message) || "unknown"));
      root.invalidate();
    });
    return true;
  }

  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.connKey, this.sessionId, true).catch(() => {});
  }

  // Re-pull the outline on a structural change; a missing replica must not empty the pane and drop the fold overrides.
  reload() {
    if (!this.sessionId) return;
    const o = client.sessionOutline(this.connKey, this.sessionId);
    if (!o || !Array.isArray(o.messages)) return;
    this.transcript.setOutline(o.messages, o.active || null);
    root.invalidate();
  }

  // A draft delta: re-wrap only the streaming message `id`.
  /** @param {number} id */
  active(id) {
    this.transcript.setActive(id);
    root.invalidate();
  }

  // Create the session, mount it, then send the first message, because the daemon makes a session only on demand.
  /** @param {string} text @returns {boolean} */
  startChat(text) {
    if (this.creating) return false;
    if (this.connKey !== LOCAL) {
      notice.show("a new chat needs the local daemon");
      return false;
    }
    if (!term.cwd) {
      notice.show("no workspace directory");
      return false;
    }
    const connKey = this.connKey;
    const d = defaultModel();
    const params = /** @type {CreateSessionDraft} */ ({ workspace_path: term.cwd });
    if (d.model) params.model = d.model;
    if (d.reasoning) params.reasoning = d.reasoning;
    const token = ++this.gen;
    this.creating = true;
    client
      .sessionCreate(connKey, params)
      .then((r) => {
        // A cancelled create unmounts its replica, but the protocol has no delete, so the empty session stays.
        if (token !== this.gen) {
          client.sessionClose(connKey, r.session.id);
          return null;
        }
        this.open(connKey, r.session.id);
        return client.sessionSendInput(connKey, r.session.id, text);
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

  // Leave the open session and show an empty pane; the daemon makes the next session on the first message.
  newChat() {
    this.gen++;
    this.creating = false;
    this.release();
    this.sessionId = null;
    this.connKey = LOCAL;
    this.transcript.setOutline([], null);
    root.focusView(this.view);
    root.invalidate();
  }

  // The daemon lost the session. Clear the pane back to the placeholder.
  sessionGone() {
    this.sessionId = null;
    this.transcript.setOutline([], null);
    root.invalidate();
  }

  // Tell the daemon this pane is done with the session, unless another pane still shows it.
  release() {
    if (!this.sessionId) return;
    for (const c of chats) {
      if (c !== this && c.connKey === this.connKey && c.sessionId === this.sessionId) return;
    }
    client.sessionClose(this.connKey, this.sessionId);
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

// The focused chat's live entry, or null with no open session.
/** @returns {FeedItem | null} */
export function chatEntry() {
  const c = focusedChat();
  if (!c || !c.sessionId) return null;
  return feedItem(c.connKey, c.sessionId);
}

// Pick any message in the transcript and copy its source text.
/** @param {import("yuke:ext").Context} ctx */
function openMessagePicker(ctx) {
  const c = focusedChat();
  if (!c) return null;
  const t = c.transcript;
  const items = t.messages().map((m, i) => ({ m, i, text: t.textFor(m) }));
  if (items.length === 0) {
    notice.show("nothing to copy");
    return null;
  }
  const picked = ui.pick({
    title: "copy a message",
    footer: "type to filter · ↵ copy · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.5,
    items: items.reverse(),
    key: r => r.m.id,
    filterText: r => r.text,
    format: r => ({ text: firstLine(r.text) || "(empty)", right: r.m.type }),
    onAccept: r => copy(r.text, r.m.type + " message"),
  });
  ctx.overlay(picked.win);
  return picked;
}

// Load the catalog, then pick a model and its effort. The pick happens after the load returns.
/** @param {import("yuke:ext").Context} ctx */
function openModelPicker(ctx) {
  const chat = focusedChat();
  if (!chat) return null;
  const connKey = chat.connKey;
  const current = chatEntry();
  const currentId = current && current.session ? current.session.model : null;
  const show = () => {
    const models = catalogOf(connKey).models.slice().sort((a, b) => a.provider.localeCompare(b.provider) || a.name.localeCompare(b.name));
    if (models.length === 0) {
      notice.show("no model in the catalog");
      return null;
    }
    // The daemon owns the selector format. The picker keys on it and never builds one.
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
      format: m => ({ text: m.name, right: m.provider }),
      onAccept: m => pickReasoning(ctx, connKey, m),
    });
    ctx.overlay(p.win);
    p.content.selectKey(currentId);
    return p;
  };
  loadCatalog(connKey).then(show);
  return null;
}

// A model with one level needs no second step, so the pick ends there.
/** @param {import("yuke:ext").Context} ctx @param {string} connKey @param {Wire.ModelInfo} model @returns {void} */
function pickReasoning(ctx, connKey, model) {
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
  ctx.overlay(step.win);
  step.content.selectKey(model.default_reasoning || levels[0]);
}

/** @param {import("yuke:ext").Context} ctx */
function openCodePicker(ctx) {
  const c = focusedChat();
  if (!c) return null;
  const blocks = c.transcript.codeBlocks();
  if (blocks.length === 0) {
    notice.show("no code block");
    return null;
  }
  const picked = ui.pick({
    title: "copy a code block",
    footer: "type to filter · ↵ copy · esc close",
    border: "rounded",
    width: 0.6,
    height: 0.5,
    items: blocks.map((b, i) => ({ ...b, i })),
    key: b => b.i,
    filterText: b => b.lang + " " + b.text,
    format: b => ({ text: firstLine(b.text) || "(empty)", right: b.lang }),
    onAccept: b => copy(b.text, b.lang ? b.lang + " block" : "code block"),
  });
  ctx.overlay(picked.win);
  return picked;
}

// The first line of `s`, for a one-row picker label.
/** @param {string} s @returns {string} */
function firstLine(s) {
  const i = s.indexOf("\n");
  return (i < 0 ? s : s.slice(0, i)).trim();
}

// The chat's own listeners and the commands that read its transcript.
export const chatPlugin = {
  name: "chat",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    // Two panes can show one session, so the event reaches every pane that names it.
    ctx.on("session.changed", /** @param {NativeSessionEvent} ev */ (ev => {
      if (!ev) return;
      for (const c of chats) {
        if (c.connKey !== ev.connKey || c.sessionId !== ev.sessionId) continue;
        if (ev.kind === "gone") c.sessionGone();
        else if (ev.kind === "active") c.active(/** @type {number} */ (ev.id));
        else c.reload();
      }
    }));

    ctx.on("conn.changed", /** @param {NativeConnEvent} ev */ (ev => {
      if (!ev || !ev.key) return;
      if (ev.kind !== "ready") return;
      loadCatalog(ev.key);
      if (ev.key === LOCAL) events.emit("daemon.ready");
      // A reconnect lost the mount, so each pane on that connection re-opens its own session.
      for (const c of chats) {
        if (c.connKey === ev.key && c.sessionId && client.sessionRev(ev.key, c.sessionId) < 0) c.open(ev.key, c.sessionId);
      }
      root.invalidate();
    }));

    // A closed pane must not keep its session mounted on the daemon.
    ctx.on("pane.closed", view => {
      const c = chatOf(view);
      if (c) c.dispose();
    });

    ctx.command(null, {
      "copy:message": () => openMessagePicker(ctx),
      "copy:code": () => openCodePicker(ctx),
      "model:pick": () => openModelPicker(ctx),
    });
  },
};
