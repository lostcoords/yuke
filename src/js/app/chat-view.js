// Own the chat layout, composer, and empty-chat hint.
import { term } from "yuke:internal/native/term";
import { text, claimView, contains, copy } from "yuke:internal/core";
import { config, events } from "yuke:internal/kernel";
import { clip } from "yuke:internal/text-input";
import { Composer, Text } from "yuke:internal/ui";
import { Transcript } from "yuke:internal/transcript";
import { pasteAttaches } from "yuke:internal/attach";

/** @typedef {"composer" | "transcript"} ChatRegion */
/** @typedef {{ text: string, group?: string }} StripRow */
/** @import { Session } from "yuke:internal/chat" */
/** @import { HostMouseEvent as MouseEvent, NavTarget, Rect } from "./types/core.js" */

// A chat pane asks these points; the newest listener that answers wins, so a plugin can supply a value it does not own.
events.declare(["chat.press", "chat.strip", "chat.rule", "chat.cursor"]);

// A drag that ends copies the selection when the config asks; one function serves every view.
/** @param {string} text @returns {void} */
function copySelection(text) {
  if (config.mouse.copyOnSelect) copy(text, "selection");
}

// The chat pane: a transcript above a composer in one leaf. Draw, layout, and mouse routing.
export class ChatView {
  // The view reads and sends through `session`; `showSession` moves it to another one.
  /** @param {Session} session */
  constructor(session) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.session = session;
    session.views.add(this);
    this.transcript = new Transcript({
      partsOf: (id) => this.session.partsOf(id),
      partOf: (id, partId, previous) => this.session.partOf(id, partId, previous),
      partTextPage: (id, partId, field, offset, limit) => this.session.partTextPage(id, partId, field, offset, limit),
      onSelect: copySelection,
    });
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
    /** @type {StripRow[]} */
    this.strip = [];
    // This field names the region that reads the keyboard. The mouse routes by rect instead.
    /** @type {ChatRegion} */
    this.focus = "composer";
  }

  get name() {
    return "chat";
  }

  // The focused region names the deeper atom, so a binding can own one region alone.
  /** @returns {string[]} */
  contexts() {
    return ["chat", this.focus];
  }

  // A pane focus returns the keyboard to the composer.
  onFocus() {
    this.focusRegion("composer");
  }

  /** @param {ChatRegion} name */
  focusRegion(name) {
    if (name !== "composer" && name !== "transcript") throw new TypeError("focusRegion: unknown region " + name);
    if (this.focus === name) return;
    this.focus = name;
    events.emit("region.focused", this, name);
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    // A focused transcript reads nothing here, because a nav binding scrolls it through the keymap.
    if (this.focus === "transcript") return false;
    return this.composer.onKey(ev);
  }

  // The widget a nav binding drives here. The transcript scrolls even while the composer types.
  /** @returns {NavTarget | null} */
  navTarget() {
    return this.transcript.pager;
  }

  // Route by sub-rect, so a wheel step over the composer never moves the transcript; only a press hits this test.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    if (ev.event === "drag" || ev.event === "release") return this.transcript.onMouse(ev);
    const r = this.transcript.pager.rect();
    const inside = r && contains(r, ev.col, ev.row);
    const taken = inside ? this.transcript.onMouse(ev) : false;
    // A provider may claim a left press to place its own caret, after the transcript reads it.
    if (ev.event !== "press" || ev.button !== "left") return taken;
    return events.bail("chat.press", this, ev) === true || taken;
  }

  // Stack the transcript, the strip, the rule, and the composer; the transcript takes the rows the others leave.
  /** @param {Rect} bounds @returns {void} */
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
    if (this.transcript._messages.length === 0 && !this.transcript._active && !this.session.sessionId) {
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

  /** @param {boolean} [focused] @returns {void} */
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

  // The rule row. A plugin puts a line on it, such as the working indicator, and the rule fills the rest.
  /** @param {number} x @param {number} y @param {number} w @returns {void} */
  _drawRule(x, y, w) {
    const line = events.bail("chat.rule", this);
    const label = line ? clip(line.text, w) : "";
    const used = label ? term.measure(label) : 0;
    if (label) text(x, y, label, (line && line.group) || "YukeRule");
    if (w > used) text(x + used, y, "─".repeat(w - used), "YukeRule");
  }

  // The caret belongs to the focused region, so a transcript with no cursor provider shows none.
  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    const supplied = events.bail("chat.cursor", this);
    if (supplied) return supplied;
    return this.focus === "composer" ? this.composer.cursor() : null;
  }
}

/** @param {Rect} rect @param {number} x @param {number} y @param {number} w @param {number} h @returns {void} */
function setRect(rect, x, y, w, h) {
  rect.x = x;
  rect.y = y;
  rect.w = w;
  rect.h = h;
}
