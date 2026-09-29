// Own the chat layout, composer, and empty-chat hint.
import { term } from "yuke:internal/native/term";
import { root, text, claimView, contains, copy } from "yuke:internal/core";
import { config, events } from "yuke:internal/kernel";
import { clip } from "yuke:internal/text-input";
import { Composer, Text } from "yuke:internal/ui";
import { Transcript } from "yuke:internal/transcript";
import { client } from "yuke:internal/client";
import { pasteAttaches } from "yuke:internal/attach";

/**
 * A region of the chat pane that can take the keyboard.
 * @typedef {"composer" | "transcript"} ChatRegion
 */
/**
 * One line of text that a `chat.strip` or `chat.rule` listener answers. `group` names its highlight group; each place has its own default.
 * @typedef {{ text: string, group?: string }} StripRow
 */
/** @import { Session } from "yuke:internal/session" */
/** @import { HostMouseEvent as MouseEvent, NavTarget, Rect } from "./types/core.js" */

// A chat pane asks these points; the newest listener that answers wins, so a plugin can supply a value it does not own.
events.declare(["chat.press", "chat.strip", "chat.rule", "chat.cursor"]);

// A drag that ends copies the selection when the config asks; one function serves every view.
/** @param {string} text @returns {void} */
function copySelection(text) {
  if (config.mouse.copyOnSelect) copy(text, "selection");
}

/**
 * The chat pane: a transcript above a composer in one leaf. Plugins extend it through events, and the newest listener that answers wins:
 * `chat.press` claims a left press, `chat.strip` adds rows under the transcript, `chat.rule` puts a line on the rule, and `chat.cursor` places the caret.
 */
export class ChatView {
  /**
   * The pane joins `session` at once, so it appears in `session.views`.
   * @param {Session} session
   */
  constructor(session) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    /** The session that this pane reads and sends through. To move the pane to another session, use `showSession` or `openSession`. */
    this.session = session;
    session.join(this);
    /** The messages of the shown session. It reads parts straight from the engine for the current `session`; a draft has none. */
    this.transcript = new Transcript({
      partsOf: (id) => {
        const sid = this.session.sessionId;
        return sid ? client.sessionParts(sid, id) : [];
      },
      partOf: (id, partId, cursor) => {
        const sid = this.session.sessionId;
        return sid ? client.sessionPart(sid, id, partId, cursor) : null;
      },
      partTextPage: (id, partId, field, offset, limit) => {
        const sid = this.session.sessionId;
        return sid ? client.partTextPage(sid, id, partId, field, offset, limit) : { text: "", next: null };
      },
      onSelect: copySelection,
    });
    /** The input box. A submit sends its content through `session.send`, and a pasted image path becomes an attachment. */
    this.composer = new Composer({ placeholder: "Message…", onSubmit: (content) => this.session.send(content, this.composer) });
    // A pasted image path attaches here instead of staying text; every other paste keeps its old behavior.
    this.composer.onPaste = (text, from) => pasteAttaches(this.composer, text, from);
    claimView(this.composer, this);
    // An empty draft shows these in the transcript region until its first message.
    this.title = new Text({ text: "new chat", group: "YukeBrand" });
    this.hint = new Text({ group: "YukeEmpty" });
    // Each layout writes these rects in place, so a frame allocates none.
    this.transcriptRect = { x: 0, y: 0, w: 0, h: 0 };
    this.stripRect = { x: 0, y: 0, w: 0, h: 0 };
    this.ruleRect = { x: 0, y: 0, w: 0, h: 0 };
    this.composerRect = { x: 0, y: 0, w: 0, h: 0 };
    this.titleRect = { x: 0, y: 0, w: 0, h: 0 };
    this.hintRect = { x: 0, y: 0, w: 0, h: 0 };
    /**
     * The rows that `chat.strip` answered at the last layout.
     * @type {StripRow[]}
     */
    this.strip = [];
    /**
     * The region that reads the keyboard. The mouse routes by rect instead. To change it, use `focusRegion`.
     * @type {ChatRegion}
     */
    this.focus = "composer";
  }

  /** Always "chat". */
  get name() {
    return "chat";
  }

  /**
   * The keymap contexts of this pane: "chat", then the focused region. So a binding can own one region alone.
   * @returns {string[]}
   */
  contexts() {
    return ["chat", this.focus];
  }

  /** A pane focus gives the keyboard back to the composer. */
  onFocus() {
    this.focusRegion("composer");
  }

  /**
   * Give the keyboard to region `name`, and emit `region.focused` when the region changes. Throws a TypeError for an unknown region.
   * @param {ChatRegion} name
   */
  focusRegion(name) {
    if (name !== "composer" && name !== "transcript") throw new TypeError("focusRegion: unknown region " + name);
    if (this.focus === name) return;
    this.focus = name;
    events.emit("region.focused", this, name);
  }

  /**
   * Send a key to the composer. It returns false while the transcript has focus, because keymap bindings move the transcript.
   * @param {HostEvent} ev @returns {boolean}
   */
  onKey(ev) {
    // A focused transcript reads nothing here, because a nav binding scrolls it through the keymap.
    if (this.focus === "transcript") return false;
    return this.composer.onKey(ev);
  }

  /**
   * The widget that a nav binding drives here: the transcript pager. The transcript scrolls even while the composer has focus.
   * @returns {NavTarget | null}
   */
  navTarget() {
    return this.transcript.pager;
  }

  /**
   * Route a mouse event by sub-rect, so a wheel step over the composer never moves the transcript. A drag or a release always goes to the transcript.
   * After the transcript reads a left press, a `chat.press` listener can claim it.
   * @param {MouseEvent} ev @returns {boolean}
   */
  onMouse(ev) {
    if (ev.event === "drag" || ev.event === "release") return this.transcript.onMouse(ev);
    const r = this.transcript.pager.rect();
    const inside = r && contains(r, ev.col, ev.row);
    const taken = inside ? this.transcript.onMouse(ev) : false;
    // A provider may claim a left press to place its own caret, after the transcript reads it.
    if (ev.event !== "press" || ev.button !== "left") return taken;
    return events.bail("chat.press", this, ev) === true || taken;
  }

  /**
   * Stack the transcript, the strip, the rule, and the composer; the transcript takes the rows the others leave. The composer takes at most half the pane.
   * Each layout asks `chat.strip` for the strip rows. An empty draft shows its title and hint in the transcript region.
   * @param {Rect} bounds @returns {void}
   */
  layout(bounds) {
    this.rect = bounds;
    const { x, y, w, h } = bounds;
    const composerRows = w > 0 && h > 0 ? Math.min(this.composer.height(w), Math.max(1, Math.floor(h / 2))) : 0;
    this.strip = events.bail("chat.strip", this) || [];
    const stripRows = Math.min(this.strip.length, Math.max(0, h - composerRows - 2));
    const ruleRows = h > composerRows && w > 0 ? 1 : 0;
    const transcriptRows = h - composerRows - stripRows - ruleRows;
    // The composer is at most half the pane and the strip leaves two rows, so the three fit.
    if (transcriptRows < 0) throw new Error("chat rows exceed the pane");
    setRect(this.stripRect, x, y + transcriptRows, w, stripRows);
    setRect(this.ruleRect, x, y + transcriptRows + stripRows, w, ruleRows);
    setRect(this.composerRect, x, y + transcriptRows + stripRows + ruleRows, w, composerRows);
    this.composer.layout(this.composerRect);
    // An empty draft shows the hint where the transcript goes; the model line reads the model its first input takes.
    if (this.transcript.isEmpty() && !this.session.sessionId) {
      const model = this.session.modelSelector();
      this.hint.setText((model ? "model · " + model : "no model yet") + "\ntype a message to start the session");
      setRect(this.titleRect, x + 2, y, Math.max(0, w - 2), Math.min(1, transcriptRows));
      setRect(this.hintRect, x + 2, y + this.titleRect.h, Math.max(0, w - 2), transcriptRows - this.titleRect.h);
      this.title.layout(this.titleRect);
      this.hint.layout(this.hintRect);
      setRect(this.transcriptRect, x, y, 0, 0);
    } else {
      setRect(this.titleRect, x, y, 0, 0);
      setRect(this.hintRect, x, y, 0, 0);
      setRect(this.transcriptRect, x, y, w, transcriptRows);
    }
    if (this.transcriptRect.w === 0 || this.transcriptRect.h === 0) this.transcript.hide();
  }

  /**
   * Draw the pane into the rects of the last layout.
   * @param {boolean} [focused] @returns {void}
   */
  draw(focused = false) {
    if (this.rect.w <= 0 || this.rect.h <= 0) return;
    const transcript = this.transcriptRect;
    if (transcript.w > 0 && transcript.h > 0) this.transcript.draw(transcript);
    if (this.titleRect.h > 0) this.title.draw();
    if (this.hintRect.h > 0) this.hint.draw();
    for (let i = 0; i < Math.min(this.strip.length, this.stripRect.h); i++) {
      const row = /** @type {StripRow} */ (this.strip[i]);
      text(this.stripRect.x, this.stripRect.y + i, clip(row.text, this.stripRect.w), row.group || "UIDim");
    }
    if (this.ruleRect.h > 0) this._drawRule(this.ruleRect.x, this.ruleRect.y, this.ruleRect.w);
    this.composer.draw(focused);
  }

  /**
   * Draw the rule row. A `chat.rule` listener puts a line on it, such as the working indicator, and the rule fills the rest.
   * @param {number} x @param {number} y @param {number} w @returns {void}
   */
  _drawRule(x, y, w) {
    const line = events.bail("chat.rule", this);
    const label = line ? clip(line.text, w) : "";
    const used = label ? term.measure(label) : 0;
    if (label) text(x, y, label, (line && line.group) || "YukeRule");
    if (w > used) text(x + used, y, "─".repeat(w - used), "YukeRule");
  }

  /**
   * The caret: the `chat.cursor` answer, else the composer caret while the composer has focus, else null.
   * @returns {{ x: number, y: number, visible: boolean } | null}
   */
  cursor() {
    const supplied = events.bail("chat.cursor", this);
    if (supplied) return supplied;
    return this.focus === "composer" ? this.composer.cursor() : null;
  }
}

// The focused pane when it is a chat pane: the composer and transcript regions exist only there.
/** @returns {ChatView | null} */
export function focusedChat() {
  return root.active instanceof ChatView ? root.active : null;
}

/** @param {Rect} rect @param {number} x @param {number} y @param {number} w @param {number} h @returns {void} */
function setRect(rect, x, y, w, h) {
  rect.x = x;
  rect.y = y;
  rect.w = w;
  rect.h = h;
}
