// yuke:chat — the chat pane, the session it drives, and the pickers that read its transcript.
import { root, config, copy, events } from "yuke:core";
import { term } from "yuke:term";
import { ui } from "yuke:ui";
import { ChatView } from "yuke:transcript";
import * as client from "yuke:client";
import { notice } from "yuke:notice";
import { feedItem } from "yuke:sidebar";
import { catalogOf, loadCatalog, chooseModel, defaultModel } from "yuke:catalog";

const LOCAL = client.LOCAL;

/** @typedef {{ connKey: string, sessionId: string | null, creating: boolean, gen: number, open: (connKey: string, id?: string | null) => void, send: (text: string) => boolean, interrupt: () => void, reload: () => void, active: (id: number) => void, startChat: (text: string) => boolean, newChat: () => void, close: () => void }} ChatSession */
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

export const chat = new ChatView({
  textOf: id => (chatSession.sessionId ? client.sessionText(chatSession.connKey, chatSession.sessionId, id) : ""),
  partsOf: id => (chatSession.sessionId ? client.sessionParts(chatSession.connKey, chatSession.sessionId, id) : []),
  onSubmit: text => chatSession.send(text),
  onSelect: text => {
    if (config.mouse.copyOnSelect) copy(text, "selection");
  },
  empty: () => (chatSession.sessionId ? null : newChatLines()),
});

// Drive one mounted pair into the chat pane: open and resync, then react to each "session" event.
/** @type {ChatSession} */
export const chatSession = {
  connKey: LOCAL,
  sessionId: null,
  creating: false,
  gen: 0,

  /** @param {string} connKey @param {string | null | undefined} id */
  open(connKey, id) {
    if (id == null) {
      id = connKey;
      connKey = LOCAL;
    }
    if (this.sessionId && (this.connKey !== connKey || this.sessionId !== id)) {
      client.sessionClose(this.connKey, this.sessionId);
    }
    this.connKey = connKey;
    this.sessionId = id;
    client.sessionOpen(this.connKey, id);
    client.sessionResync(this.connKey, id).catch(() => {});
    this.reload();
  },

  // Send composer text into the open session. It returns false with no session, so the composer
  // keeps the text; the message appears through the "session" fold, not optimistically.
  /** @param {string} text @returns {boolean} */
  send(text) {
    if (!this.sessionId) return this.startChat(text);
    client.sessionSendInput(this.connKey, this.sessionId, text).catch((e) => {
      restoreInput(text);
      notice.show("send failed · " + ((e && e.message) || "unknown"));
      root.invalidate();
    });
    return true;
  },

  interrupt() {
    if (!this.sessionId) return;
    client.sessionCancelRun(this.connKey, this.sessionId, true).catch(() => {});
  },

  // A structural change (open, commit, resync): re-pull the outline.
  // A missing replica must not empty the pane; that would drop user fold overrides.
  reload() {
    if (!this.sessionId) return;
    const o = client.sessionOutline(this.connKey, this.sessionId);
    if (!o || !Array.isArray(o.messages)) return;
    chat.transcript.setOutline(o.messages, o.active || null);
    root.invalidate();
  },

  // A draft delta: re-wrap only the streaming message `id`.
  /** @param {number} id */
  active(id) {
    chat.transcript.setActive(id);
    root.invalidate();
  },

  // Create the session, mount it, then send the first message. The daemon makes a session only
  // once a chat has something to say.
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
        if (token !== this.gen) return null;
        this.open(connKey, r.session.id);
        return client.sessionSendInput(connKey, r.session.id, text);
      })
      .catch((e) => {
        restoreInput(text);
        notice.show("new chat failed · " + ((e && e.message) || "unknown"));
        root.invalidate();
      })
      .then(() => {
        if (token === this.gen) this.creating = false;
      });
    return true;
  },

  // Leave the open session and show an empty pane. The daemon makes the session on the first
  // message, so nothing is created until the user sends one.
  newChat() {
    this.gen++;
    this.creating = false;
    if (this.sessionId) client.sessionClose(this.connKey, this.sessionId);
    this.sessionId = null;
    this.connKey = LOCAL;
    chat.transcript.setOutline([], null);
    root.focusView(chat);
    root.invalidate();
  },

  // The daemon lost the session. Clear the pane back to the placeholder.
  close() {
    this.sessionId = null;
    chat.transcript.setOutline([], null);
    root.invalidate();
  },
};

/** @param {string} text @returns {void} */
function restoreInput(text) {
  const now = chat.composer.text;
  chat.composer.text = now === "" ? text : text + "\n" + now;
}

// The chat's live entry, or null with no open session.
/** @returns {FeedItem | null} */
export function chatEntry() {
  if (!chatSession.sessionId) return null;
  return feedItem(chatSession.connKey, chatSession.sessionId);
}

// Pick any message in the transcript and copy its source text.
export function openMessagePicker() {
  const items = chat.transcript.messages().map((m, i) => ({ m, i, text: chat.transcript.textFor(m) }));
  if (items.length === 0) {
    notice.show("nothing to copy");
    return null;
  }
  return ui.pick({
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
}

// Pick any fenced code block in the transcript and copy its body.
export function openModelPicker() {
  const connKey = chatSession.connKey;
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
      onAccept: m => pickReasoning(connKey, m),
    });
    p.content.selectKey(currentId);
    return p;
  };
  loadCatalog(connKey).then(show);
  return null;
}

// A model with one level needs no second step, so the pick ends there.
/** @param {string} connKey @param {Wire.ModelInfo} model @returns {void} */
function pickReasoning(connKey, model) {
  const levels = model.reasoning_levels;
  if (levels.length < 2) {
    chooseModel(model, model.default_reasoning || levels[0] || "");
    return;
  }
  ui.pick({
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
  }).content.selectKey(model.default_reasoning || levels[0]);
}

export function openCodePicker() {
  const blocks = chat.transcript.codeBlocks();
  if (blocks.length === 0) {
    notice.show("no code block");
    return null;
  }
  return ui.pick({
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
    ctx.on("session.changed", /** @param {NativeSessionEvent} ev */ (ev => {
      if (!ev || ev.connKey !== chatSession.connKey || ev.sessionId !== chatSession.sessionId) return;
      if (ev.kind === "gone") chatSession.close();
      else if (ev.kind === "active") chatSession.active(/** @type {number} */ (ev.id));
      else chatSession.reload();
    }));

    ctx.on("conn.changed", /** @param {NativeConnEvent} ev */ (ev => {
      if (!ev || !ev.key) return;
      if (ev.kind !== "ready") return;
      loadCatalog(ev.key);
      if (ev.key === LOCAL) events.emit("daemon.ready");
      if (chatSession.connKey === ev.key && chatSession.sessionId && client.sessionRev(ev.key, chatSession.sessionId) < 0) {
        chatSession.open(ev.key, chatSession.sessionId);
      }
      root.invalidate();
    }));

    ctx.command(null, {
      "copy:message": () => openMessagePicker(),
      "copy:code": () => openCodePicker(),
      "model:pick": () => openModelPicker(),
    });
  },
};
