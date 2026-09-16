import { text } from "yuke:core";
import { clip } from "yuke:text-input";
import { strokeOf } from "yuke:keys";

/** @import { Rect } from "./types/core.js" */

// A two-column information panel shares the cache and context window layout.
export class InfoPanel {
  /** @param {[string, string][]} rows @param {() => void} onClose */
  constructor(rows, onClose) {
    this.rows = rows;
    this.onClose = onClose;
    /** @type {Rect} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** @param {Rect} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    for (let i = 0; i < this.rows.length && i < h; i++) {
      const row = /** @type {[string, string]} */ (this.rows[i]);
      text(x, y + i, clip(row[0].padEnd(12), w), "UIDim");
      if (w > 12) text(x + 12, y + i, clip(row[1], w - 12), "UIQuery");
    }
  }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type === "key" && (strokeOf(event) === "esc" || strokeOf(event) === "q")) this.onClose();
    return true;
  }
}
