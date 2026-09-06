// yuke:interaction-ui — the terminal answerer for the shared interaction capability.
import { native } from "yuke:interaction-native";
import { DeviceDialog } from "yuke:auth";
import { root } from "yuke:core";
import { Prompt, Window, ui } from "yuke:ui";
import { interaction } from "yuke:ext";
import { notice } from "yuke:notice";
import { confirmRequest, inputRequest, noticeLevel, selectRequest, watchCancellation } from "yuke:interaction";

/** @typedef {() => void} Cancel */

/** @param {import("yuke:ext").InjectContext} frontend */
function createAnswerer(frontend) {
  /** @type {Set<Cancel>} */
  const pending = new Set();
  frontend.effect(() => () => {
    for (const cancel of Array.from(pending)) cancel();
  });

  return {
    /** @param {import("yuke:ext").Context} consumer */
    surfaceFor(consumer) {
      /** @type {Set<Cancel>} */
      const owned = new Set();
      consumer.effect(() => () => {
        for (const cancel of Array.from(owned)) cancel();
      });

      /** @template T @param {(settle: (value: T | undefined) => void) => Cancel} open @param {import("yuke:ext").InteractionOptions} [options] @returns {Promise<T | undefined>} */
      const dialog = (open, options) => new Promise((resolve, reject) => {
        if (options?.signal?.aborted) { resolve(undefined); return; }
        let unwatch = () => {};
        let done = false;
        /** @type {Cancel} */
        let cancel = () => {};
        /** @param {T | undefined} value */
        const settle = (value) => {
          if (done) return;
          done = true;
          unwatch();
          pending.delete(cancel);
          owned.delete(cancel);
          cancel();
          resolve(value);
        };
        const close = open(settle);
        cancel = () => {
          close();
          settle(undefined);
        };
        pending.add(cancel);
        owned.add(cancel);
        unwatch = watchCancellation(options?.signal, cancel, (error) => { reject(error); cancel(); });
      });

      /** @param {string} title @param {import("yuke:ext").InteractionOptions | undefined} options */
      const attributedTitle = (title, options) => {
        const id = options?.signal ? native.sessionId(options.signal) : null;
        return id ? "session " + id.slice(0, 8) + " · " + title : title;
      };
      return {
        interactive: true,
        /** @param {Wire.AuthLoginResult} start @param {Promise<Wire.AuthLoginOutcome>} outcome @param {import("yuke:ext").InteractionOptions} [options] */
        deviceLogin(start, outcome, options) {
          return dialog((settle) => {
            const device = new DeviceDialog(start);
            device.onCancel = () => settle(undefined);
            const win = new Window({ title: attributedTitle("Provider login", options), footer: "c copy code · o open browser · esc cancel", border: "rounded", width: 0.7, height: 5, content: device });
            root.pushOverlay(win);
            outcome.then(settle);
            return frontend.tui.overlay(win);
          }, options);
        },
        /** @param {string} title @param {string} [message] @param {import("yuke:ext").InteractionOptions} [options] @returns {Promise<boolean | undefined>} */
        confirm(title, message = "", options) {
          const request = confirmRequest(title, message);
          return dialog((settle) => {
            const items = [
              { id: "message", text: request.message, answer: undefined },
              { id: "yes", text: "yes", answer: true },
              { id: "no", text: "no", answer: false },
            ];
            const picked = ui.select(items, {
              title: attributedTitle(request.title, options),
              footer: "↵ answer · esc cancel",
              border: "rounded",
              width: 0.6,
              height: 7,
              key: (item) => item.id,
              isSelectable: (item) => item.answer !== undefined,
              format: (item) => ({ text: item.text, group: item.answer === undefined ? "UIDim" : "UIItem" }),
              onAccept: (item) => settle(item.answer),
              onCancel: () => settle(undefined),
            });
            return frontend.tui.overlay(picked.win);
          }, options);
        },

        /** @param {string} title @param {string[]} choices @param {import("yuke:ext").InteractionOptions} [options] @returns {Promise<string | undefined>} */
        select(title, choices, options) {
          const request = selectRequest(title, choices);
          return dialog((settle) => {
            const picked = ui.pick({
              items: request.options,
              title: attributedTitle(request.title, options),
              footer: "↵ select · esc cancel",
              border: "rounded",
              width: 0.6,
              height: 0.5,
              onAccept: settle,
              onCancel: () => settle(undefined),
            });
            return frontend.tui.overlay(picked.win);
          }, options);
        },

        /** @param {string} title @param {string} [placeholder] @param {import("yuke:ext").InteractionOptions} [options] @returns {Promise<string | undefined>} */
        input(title, placeholder, options) {
          const request = inputRequest(title, placeholder, options?.secret);
          return dialog((settle) => {
            const prompt = new Prompt({ placeholder: request.placeholder || "", mask: request.secret || false, settle });
            const win = new Window({
              title: attributedTitle(request.title, options),
              footer: "↵ submit · esc cancel",
              border: "rounded",
              width: 0.6,
              height: 3,
              content: prompt,
            });
            root.pushOverlay(win);
            return frontend.tui.overlay(win);
          }, options);
        },

        /** @param {string} message @param {"info" | "warn" | "error"} [level] @returns {void} */
        notify(message, level = "info") {
          noticeLevel(level);
          notice.show(message);
        },
      };
    },
  };
}

export const tuiInteractionPlugin = {
  name: "tui-interaction",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (frontend) => interaction.install(createAnswerer(frontend)));
  },
};
