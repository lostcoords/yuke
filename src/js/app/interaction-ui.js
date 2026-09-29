// The terminal answerer presents requests; the shared lifecycle owns their disposal.
import { native } from "yuke:internal/native/interaction";
import { copy, text } from "yuke:internal/core";
import { clip } from "yuke:internal/text-input";
import { strokeOf } from "yuke:internal/keys";
import { openUrl } from "yuke:internal/browser";
import { term } from "yuke:internal/native/term";
import { Prompt, Window, ui } from "yuke:internal/ui";
import { interaction, watchCancellation } from "yuke:internal/interaction";
/** @import { Context } from "yuke:internal/ext" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Answerer } from "./types/runtime.js" */

// The device-code step: the URL to open and the code to enter. The engine polls; this window only waits.
class DeviceDialog {
  /** @param {Wire.AuthLoginResult} start */
  constructor(start) {
    this.start = start;
    /** @type {(() => void) | null} */
    this.onCancel = null;
    /** @type {{ x: number, y: number, w: number, h: number }} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** @param {{ x: number, y: number, w: number, h: number }} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    text(x, y, clip("open  ", w), "UIDim");
    if (w > 6) text(x + 6, y, clip(this.start.verification_url, w - 6), "UIQuery");
    if (this.rect.h <= 1) return;
    text(x, y + 1, clip("code  ", w), "UIDim");
    if (w > 6) text(x + 6, y + 1, clip(this.start.user_code, w - 6), "UITitle");
    if (this.rect.h <= 2) return;
    text(x, y + 2, clip("waiting for the provider…", w), "UIDim");
  }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type !== "key") return true;
    const s = strokeOf(event);
    if (s === "esc" && this.onCancel) this.onCancel();
    else if (s === "c") copy(this.start.user_code, "code");
    else if (s === "o") openUrl(this.start.verification_url);
    return true;
  }
}

/** @param {InjectContext} frontend @returns {Answerer} */
function createAnswerer(frontend) {
  return {
    interactive: true,
    open(request, consumer, options, resolve, reject) {
      const id = options?.signal ? native.sessionId(options.signal) : null;
      const title = id ? "session " + id.slice(0, 8) + " · " + request.title : request.title;
      const cancel = () => resolve(undefined);
      /** @type {Window} */
      let win;
      switch (request.type) {
        case "confirm": {
          const labels = options?.labels || {};
          const width = () => Math.min(term.width, Math.max(8, Math.min(72, Math.round(term.width * 0.8))));
          const picked = ui.select([true, false], {
            title,
            footer: "↵ answer · pgup/pgdn scroll · esc cancel",
            border: "rounded",
            width,
            body: request.message,
            key: Number,
            format: answer => answer ? labels.accept || "Yes" : labels.cancel || "No",
            onAccept: resolve,
            onCancel: cancel,
          });
          picked.win.opts.height = () => Math.min(term.height, picked.content.preferredHeight(width()));
          win = picked.win;
          break;
        }
        case "select": {
          const picked = ui.pick({
            items: request.options,
            title,
            footer: "↵ select · esc cancel",
            border: "rounded",
            width: max => Math.round(max * 0.6),
            height: max => Math.round(max * 0.5),
            onAccept: resolve,
            onCancel: cancel,
          });
          win = picked.win;
          break;
        }
        case "input": {
          const prompt = new Prompt({ placeholder: request.placeholder || "", mask: request.secret || false, settle: resolve });
          // A stray click must not throw away the typed text.
          win = new Window({ title, footer: "↵ submit · esc cancel", border: "rounded", outsidePress: "ignore", width: max => Math.round(max * 0.6), contentHeight: 1, content: prompt });
          break;
        }
        case "device_login": {
          const device = new DeviceDialog(request.start);
          device.onCancel = cancel;
          // The click that focuses the terminal after the browser must not cancel the login.
          win = new Window({ title, footer: "c copy code · o open browser · esc cancel", border: "rounded", outsidePress: "ignore", width: max => Math.round(max * 0.7), contentHeight: 3, content: device });
          request.outcome.then(resolve, reject);
          break;
        }
      }
      const close = frontend.tui.overlay(win);
      try {
        const unwatch = watchCancellation(options?.signal, cancel);
        return () => { unwatch(); close(); };
      } catch (error) {
        close();
        throw error;
      }
    },
  };
}

export const tuiInteractionPlugin = {
  name: "tui-interaction",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], frontend => interaction.install(createAnswerer(frontend)));
  },
};
