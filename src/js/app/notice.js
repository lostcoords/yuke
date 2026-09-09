// yuke:notice — the short message line on the left of the status bar.
import { root } from "yuke:core";
import { term } from "yuke:term";

/** @import { EngineEvent } from "yuke:engine-native" */

// The message itself. A caller keeps its own reference, so this survives a plugin unload.
export const notice = {
  text: "",

  /** @param {string} s */
  show(s) {
    this.text = s;
    root.invalidate();
  },

  clear() {
    if (this.text === "") return;
    this.text = "";
    root.invalidate();
  },
};

// The registrations that draw and drive the message. An unload stops them and leaves the object.
export const noticePlugin = {
  name: "notice",
  /** @param {import("yuke:ext").Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // A load starts clean, so a reload never shows the message an unload left behind.
      notice.clear();

      // Clear the notice before each key press dispatches. A key release must not clear a fresh notice.
      ctx.on("key.press", /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {void} */ (ev) => {
        if (ev.event === "press") notice.clear();
      });

      // A byte count means the sequence left this process, not that the terminal accepted it.
      ctx.on("clipboard.copied", /** @param {{ text: string, bytes: number, what: string }} e @returns {void} */ (e) => {
        if (!e) return;
        if (e.text === "") notice.show("nothing to copy");
        else if (e.bytes < 0) notice.show("too large to copy · over " + term.clipboardMax + " bytes");
        else notice.show("copied " + e.what + " · " + e.bytes + " bytes");
      });

      // The native digest carries the complete body because the fact name has no message.
      ctx.on("notice", /** @param {Extract<EngineEvent, { type: "index" }>} ev @returns {void} */ (ev) => {
        const notes = ev?.notices;
        const latest = notes && notes[notes.length - 1];
        if (latest) notice.show(latest.message);
      });

      ctx.tui.status({ side: "left", order: 0, render: () => notice.text });
      });
},
};
