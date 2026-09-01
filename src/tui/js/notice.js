// yuke:notice — the short message line on the left of the status bar.
import { root } from "yuke:core";
import { term } from "yuke:term";

// The message itself. A caller keeps its own reference, so this survives a plugin unload.
export const notice = {
  text: "",

  /** @param {string} s @returns {void} */
  show(s) {
    this.text = s;
    root.invalidate();
  },

  /** @returns {void} */
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
    // Clear the notice before each key press dispatches. A key release must not clear a fresh notice.
    ctx.on("key.press", /** @param {Extract<HostEvent, { type: "key" }>} ev @returns {void} */ (ev) => {
      if (ev.event === "press") notice.clear();
    });

    // Report every copy, wherever it came from. OSC 52 has no acknowledgement, so a byte count means
    // the sequence left this process, not that the terminal accepted it.
    ctx.on("clipboard.copied", /** @param {{ text: string, bytes: number, what: string }} e @returns {void} */ (e) => {
      if (!e) return;
      if (e.text === "") notice.show("nothing to copy");
      else if (e.bytes < 0) notice.show("too large to copy · over " + term.clipboardMax + " bytes");
      else notice.show("copied " + e.what + " · " + e.bytes + " bytes");
    });

    ctx.status({ side: "left", order: 0, render: () => notice.text });
  },
};
