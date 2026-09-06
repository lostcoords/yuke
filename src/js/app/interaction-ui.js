// yuke:interaction-ui — the terminal answerer for the shared interaction capability.
import { root } from "yuke:core";
import { Prompt, Window, ui } from "yuke:ui";
import { interaction } from "yuke:ext";
import { notice } from "yuke:notice";
import { confirmRequest, inputRequest, noticeLevel, selectRequest } from "yuke:interaction";

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

      /** @template T @param {(settle: (value: T | undefined) => void) => Cancel} open @returns {Promise<T | undefined>} */
      const dialog = (open) => new Promise((resolve) => {
        let done = false;
        /** @type {Cancel} */
        let cancel = () => {};
        /** @param {T | undefined} value */
        const settle = (value) => {
          if (done) return;
          done = true;
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
      });

      return {
        /** @param {string} title @param {string} [message] @returns {Promise<boolean | undefined>} */
        confirm(title, message = "") {
          const request = confirmRequest(title, message);
          return dialog((settle) => {
            const items = [
              { id: "message", text: request.message, answer: undefined },
              { id: "yes", text: "yes", answer: true },
              { id: "no", text: "no", answer: false },
            ];
            const picked = ui.select(items, {
              title: request.title,
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
          });
        },

        /** @param {string} title @param {string[]} options @returns {Promise<string | undefined>} */
        select(title, options) {
          const request = selectRequest(title, options);
          return dialog((settle) => {
            const picked = ui.select(request.options, {
              title: request.title,
              footer: "↵ select · esc cancel",
              border: "rounded",
              width: 0.6,
              height: 0.5,
              onAccept: settle,
              onCancel: () => settle(undefined),
            });
            return frontend.tui.overlay(picked.win);
          });
        },

        /** @param {string} title @param {string} [placeholder] @returns {Promise<string | undefined>} */
        input(title, placeholder) {
          const request = inputRequest(title, placeholder);
          return dialog((settle) => {
            const prompt = new Prompt({ placeholder: request.placeholder || "", settle });
            const win = new Window({
              title: request.title,
              footer: "↵ submit · esc cancel",
              border: "rounded",
              width: 0.6,
              height: 3,
              content: prompt,
            });
            root.pushOverlay(win);
            return frontend.tui.overlay(win);
          });
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
