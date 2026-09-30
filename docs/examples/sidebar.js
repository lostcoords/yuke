// A right sidebar in every chat pane: the layout solver keeps a fixed column, and the pane takes the rest. CI type-checks this file against yuke.d.ts.
import { plugins } from "yuke";
import { ChatView } from "yuke:chat";
import { layout, text, clip } from "yuke:ui";

const WIDTH = 28;
/** @type {WeakMap<ChatView, import("yuke:ui").Rect>} */
const sides = new WeakMap();

plugins.use({
  name: "sidebar",
  apply(ctx) {
    ctx.advise(ChatView.prototype, "layout", "around", function (next, bounds) {
      const solved = layout.solve(layout.row([layout.child("chat", layout.grow()), layout.child("side", layout.fixed(WIDTH))], { gap: 1 }), bounds);
      const [chat, side] = solved.children;
      if (!chat || !side) return next(bounds);
      sides.set(this, side.rect);
      return next(chat.rect);
    });
    ctx.advise(ChatView.prototype, "draw", "after", function () {
      const r = sides.get(this);
      if (!r) return;
      const lines = ["session", this.session.sessionId ?? "draft", "", "model", this.session.modelSelector() || "none"];
      for (let i = 0; i < Math.min(lines.length, r.h); i++) text(r.x, r.y + i, clip(lines[i] ?? "", r.w), i % 3 === 0 ? "UIDim" : "Normal");
    });
  },
});
