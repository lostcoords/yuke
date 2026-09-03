// yuke:interaction-ui — the terminal answerer for the shared interaction capability.
import { TextInput, caretCol, root, strokeOf } from "yuke:core";
import { Window, ui } from "yuke:ui";
import { interaction } from "yuke:ext";
import { notice } from "yuke:notice";
import { confirmRequest, inputRequest, noticeLevel, selectRequest } from "yuke:interaction";

/** @typedef {() => void} Cancel */

class Prompt {
  /** @param {string} placeholder @param {(value: string | undefined) => void} settle */
  constructor(placeholder, settle) {
    this.placeholder = placeholder;
    this.settle = settle;
    this.input = new TextInput({ onChange: () => root.invalidate() });
  }

  /** @param {Window} win @returns {void} */
  draw(win) {
    const value = this.input.text === "" ? this.placeholder : this.input.text;
    win.winText(0, 0, "› ", "UIPrompt");
    win.winText(2, 0, value, this.input.text === "" ? "UIDim" : "UIQuery");
  }

  /** @param {Window} win @returns {{ x: number, y: number, visible: boolean }} */
  cursor(win) {
    return {
      x: win.inner.x + caretCol(win.inner.w, "› ", this.input.beforeCaret()),
      y: win.inner.y,
      visible: true,
    };
  }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type !== "key") return false;
    const stroke = strokeOf(event);
    if (stroke === "enter") {
      this.settle(this.input.text);
      return true;
    }
    if (stroke === "esc") {
      this.settle(undefined);
      return true;
    }
    this.input.onKey(event);
    root.invalidate();
    return true;
  }
}

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
            const prompt = new Prompt(request.placeholder || "", settle);
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
