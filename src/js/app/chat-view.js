// Own the chat layout, composer, and presentation views.
import { term } from "yuke:term";
import { text, root, events, slot, claimView, releaseView } from "yuke:core";
import { clip } from "yuke:text-input";
import { Composer } from "yuke:ui";
import { Transcript } from "yuke:transcript";
import { column, child, fixed, fit, grow, solve } from "yuke:layout";

/** @typedef {"composer" | "transcript"} ChatRegion */
/** @typedef {{ text: string, group?: string }} StripRow */
/** @typedef {{ textOf?: ((id: number) => string) | undefined, partsOf?: PartsOf | null | undefined, partOf?: PartOf | null | undefined, partTextPage?: PartTextPage | null | undefined, onSelect?: ((text: string) => void) | null | undefined, onSubmit?: ((text: string) => boolean | void) | null | undefined, sessionId?: () => string | null }} ChatViewOptions */
/** @import { HostMouseEvent as MouseEvent, NavTarget, Rect, ViewLike as PresentationView } from "./types/core.js" */
/** @import { LayoutNode, LayoutResult } from "./types/layout.js" */
/** @typedef {{ bounds: Rect, empty: boolean, sessionId: string | null, composerRows: number, defaultLayout: LayoutNode }} PresentationContext */
/** @typedef {{ layout: (context: PresentationContext) => LayoutNode | null, dispose: () => void }} PresentationInstance */
/** @typedef {{ mount: (view: ChatView) => PresentationInstance }} PresentationProvider */
/** @import { PartOf, PartsOf, PartTextPage } from "./types/transcript.js" */

// The chat pane: a transcript above a composer in one leaf. Draw, layout, and mouse routing.
export class ChatView {
  /** @param {ChatViewOptions} [opts] */
  constructor(opts = {}) {
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.transcript = new Transcript({ textOf: opts.textOf, partsOf: opts.partsOf, partOf: opts.partOf, partTextPage: opts.partTextPage, onSelect: opts.onSelect });
    this.composer = new Composer({ placeholder: "Message…", onSubmit: opts.onSubmit });
    claimView(this.composer, this);
    this.sessionId = opts.sessionId || (() => null);
    /** @type {{ provider: PresentationProvider, instance: PresentationInstance } | null} */
    this.presentation = null;
    /** @type {PresentationView[]} */
    this.presentationViews = [];
    /** @type {PresentationView | null} */
    this.presentationFocus = null;
    /** @type {PresentationView | null} */
    this.presentationCapture = null;
    this.transcriptRect = { x: 0, y: 0, w: 0, h: 0 };
    this.stripRect = { x: 0, y: 0, w: 0, h: 0 };
    this.ruleRect = { x: 0, y: 0, w: 0, h: 0 };
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
    return this.presentationFocus ? ["chat", "presentation", ...(this.presentationFocus.contexts?.() || [])] : ["chat", this.focus];
  }

  // A pane focus returns the keyboard to the composer.
  onFocus() {
    this.focusRegion("composer");
  }

  /** @param {ChatRegion} name */
  focusRegion(name) {
    if (name !== "composer" && name !== "transcript") throw new TypeError("focusRegion: unknown region " + name);
    this.presentationFocus = null;
    if (this.focus === name) return;
    this.focus = name;
    events.emit("region.focused", this, name);
  }

  /** @param {HostEvent} ev @returns {boolean} */
  onKey(ev) {
    if (this.presentationFocus) return this.presentationFocus.onKey?.(ev) || false;
    // A focused transcript reads nothing here, because a nav binding scrolls it through the keymap.
    if (this.focus === "transcript") return false;
    return this.composer.onKey(ev);
  }

  // The widget a nav binding drives here. The transcript scrolls even while the composer types.
  /** @returns {NavTarget | null} */
  navTarget() {
    if (this.presentationFocus) return this.presentationFocus.navTarget?.() || null;
    return this.transcript.pager;
  }

  // Route by sub-rect, so a wheel step over the composer never moves the transcript; only a press hits this test.
  /** @param {MouseEvent} ev @returns {boolean} */
  onMouse(ev) {
    if (this.presentationCapture && (ev.event === "drag" || ev.event === "release")) {
      const held = this.presentationCapture;
      if (ev.event === "release") this.presentationCapture = null;
      return held.onMouse?.(ev) || false;
    }
    if (ev.event === "drag" || ev.event === "release") return this.transcript.onMouse(ev);
    for (const view of this.presentationViews) {
      const r = view.rect;
      if (ev.col < r.x || ev.col >= r.x + r.w || ev.row < r.y || ev.row >= r.y + r.h) continue;
      if (ev.event === "press" && ev.button === "left" && view.onMouse) {
        this.presentationFocus = view;
        this.presentationCapture = view;
        view.onFocus?.();
        root.invalidatePaint();
      }
      return view.onMouse?.(ev) || false;
    }
    if (ev.event === "press" && ev.button === "left") this.presentationFocus = null;
    const r = this.transcript.pager.rect();
    const inside = r && ev.col >= r.x && ev.col < r.x + r.w && ev.row >= r.y && ev.row < r.y + r.h;
    const taken = inside ? this.transcript.onMouse(ev) : false;
    // A provider may claim a left press to place its own caret, after the transcript reads it.
    if (ev.event !== "press" || ev.button !== "left") return taken;
    return slot.get(this, "press", ev) === true || taken;
  }

  /** @param {Rect} bounds @returns {void} */
  layout(bounds) {
    this.rect = bounds;
    const { w, h } = bounds;
    const composerRows = w > 0 && h > 0 ? Math.min(this.composer.height(w), Math.max(1, Math.floor(h / 2))) : 0;
    this.strip = /** @type {StripRow[]} */ (slot.get(this, "strip") || []);
    const stripRows = Math.min(this.strip.length, Math.max(0, h - composerRows - 2));
    const defaultLayout = column([
      child("transcript", grow()),
      child("strip", fixed(stripRows)),
      child("rule", fixed(h > composerRows && w > 0 ? 1 : 0)),
      child("composer", fit(), { intrinsic: { w, h: composerRows } }),
    ]);
    const context = { bounds, empty: this.transcript._messages.length === 0 && !this.transcript._active, sessionId: this.sessionId(), composerRows, defaultLayout };
    const provider = /** @type {PresentationProvider | null} */ (slot.get(this, "presentation", context));
    let tree = defaultLayout;
    try {
      if (provider !== this.presentation?.provider) {
        this.clearPresentation();
        if (provider) this.presentation = { provider, instance: provider.mount(this) };
      }
      const active = this.presentation;
      if (active) tree = active.instance.layout(context) || defaultLayout;
      if (active !== this.presentation) tree = defaultLayout;
      const placed = this.presentation;
      this._placePresentation(tree, bounds);
      if (placed !== this.presentation) {
        this._releasePresentationViews();
        this._placePresentation(defaultLayout, bounds);
      }
    } catch (error) {
      this.clearPresentation();
      events.emit("ext.error", error, "presentation");
      this._placePresentation(defaultLayout, bounds);
    }
    if (this.transcriptRect.w === 0 || this.transcriptRect.h === 0) this.transcript.hide();
  }

  /** @param {PresentationProvider} [provider] */
  clearPresentation(provider) {
    if (provider && provider !== this.presentation?.provider) return;
    const held = this.presentation;
    this.presentation = null;
    this._releasePresentationViews();
    held?.instance.dispose();
  }

  _releasePresentationViews() {
    for (const view of this.presentationViews) releaseView(view, this);
    this.presentationViews = [];
    this.presentationFocus = null;
    this.presentationCapture = null;
  }

  /** @param {LayoutNode} tree @param {Rect} bounds */
  _placePresentation(tree, bounds) {
    const result = solve(tree, bounds);
    /** @type {Map<string | PresentationView, Rect>} */
    const placements = new Map();
    /** @param {LayoutResult} item */
    const visit = item => {
      if (item.children.length) { for (const sub of item.children) visit(sub); return; }
      const value = /** @type {string | PresentationView | null} */ (item.value);
      if (value === null) return;
      if (placements.has(value)) throw new TypeError("presentation repeats a view or region");
      if (typeof value === "string") {
        if (!["transcript", "strip", "rule", "composer"].includes(value)) throw new TypeError("unknown chat region: " + value);
      } else {
        if (!value || typeof value.layout !== "function" || typeof value.draw !== "function") throw new TypeError("presentation child needs layout and draw");
        if (value === this || value === this.composer) throw new TypeError("use the composer region in a presentation");
      }
      placements.set(value, item.rect);
    };
    for (const item of result.children) visit(item);
    if (!placements.has("composer")) throw new TypeError("presentation needs one composer region");
    const empty = { x: bounds.x, y: bounds.y, w: 0, h: 0 };
    this.transcriptRect = placements.get("transcript") || empty;
    this.stripRect = placements.get("strip") || empty;
    this.ruleRect = placements.get("rule") || empty;
    this.composer.layout(/** @type {Rect} */ (placements.get("composer")));
    /** @param {PresentationView} view @returns {boolean} */
    const visible = view => {
      const rect = placements.get(view);
      return !!rect && rect.w > 0 && rect.h > 0;
    };
    for (const view of this.presentationViews) releaseView(view, this);
    if (this.presentationFocus && !visible(this.presentationFocus)) this.presentationFocus = null;
    if (this.presentationCapture && !visible(this.presentationCapture)) this.presentationCapture = null;
    this.presentationViews = [];
    for (const [view, rect] of placements) {
      if (typeof view === "string") continue;
      claimView(view, this);
      this.presentationViews.push(view);
      view.layout(rect);
    }
  }

  /** @returns {{ periodMs: number } | null} */
  needsTick() {
    let period = Infinity;
    for (const view of this.presentationViews) {
      const tick = view.needsTick?.();
      if (tick) period = Math.min(period, tick.periodMs);
    }
    return period < Infinity ? { periodMs: period } : null;
  }

  tick() {
    for (const view of this.presentationViews) if (view.needsTick?.()) view.tick?.();
  }

  /** @param {boolean} [focused] @returns {void} */
  draw(focused = false) {
    if (this.rect.w <= 0 || this.rect.h <= 0) return;
    const transcript = this.transcriptRect;
    if (transcript.w > 0 && transcript.h > 0) this.transcript.draw(transcript);
    for (let i = 0; i < Math.min(this.strip.length, this.stripRect.h); i++) {
      const row = /** @type {StripRow} */ (this.strip[i]);
      text(this.stripRect.x, this.stripRect.y + i, clip(row.text, this.stripRect.w), row.group || "UIDim");
    }
    if (this.ruleRect.h > 0) this._drawRule(this.ruleRect.x, this.ruleRect.y, this.ruleRect.w);
    this.composer.draw(focused && !this.presentationFocus);
    for (const view of this.presentationViews) if (view.rect.w > 0 && view.rect.h > 0) view.draw(focused && view === this.presentationFocus);
  }

  // The rule row. A plugin puts a line on it, such as the working indicator, and the rule fills the rest.
  /** @param {number} x @param {number} y @param {number} w @returns {void} */
  _drawRule(x, y, w) {
    const line = /** @type {StripRow | null} */ (slot.get(this, "rule"));
    const label = line ? clip(line.text, w) : "";
    const used = label ? term.measure(label) : 0;
    if (label) text(x, y, label, (line && line.group) || "YukeRule");
    if (w > used) text(x + used, y, "─".repeat(w - used), "YukeRule");
  }

  // The caret belongs to the focused region, so a transcript with no cursor provider shows none.
  /** @returns {{ x: number, y: number, visible: boolean } | null} */
  cursor() {
    if (this.presentationFocus) return this.presentationFocus.cursor?.() || null;
    const supplied = /** @type {{ x: number, y: number, visible: boolean } | null} */ (slot.get(this, "cursor"));
    if (supplied) return supplied;
    return this.focus === "composer" ? this.composer.cursor() : null;
  }
}
