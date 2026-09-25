// The terminal answerer presents requests; the shared lifecycle owns their disposal.
import { native } from "yuke:internal/native/interaction";
import { DeviceDialog } from "yuke:internal/auth";
import { term } from "yuke:internal/native/term";
import { Prompt, Window, ui } from "yuke:internal/ui";
import { interaction, watchCancellation } from "yuke:internal/interaction";
import { notice } from "yuke:internal/notice";
/** @import { Context } from "yuke:internal/ext" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { Answerer } from "./types/runtime.js" */

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
          win = new Window({ title, footer: "↵ submit · esc cancel", border: "rounded", width: max => Math.round(max * 0.6), contentHeight: 1, content: prompt });
          break;
        }
        case "device_login": {
          const device = new DeviceDialog(request.start);
          device.onCancel = cancel;
          win = new Window({ title, footer: "c copy code · o open browser · esc cancel", border: "rounded", width: max => Math.round(max * 0.7), contentHeight: 3, content: device });
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
    notify(owner, message, level) { notice.show(message); },
  };
}

export const tuiInteractionPlugin = {
  name: "tui-interaction",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], frontend => interaction.install(createAnswerer(frontend)));
  },
};
