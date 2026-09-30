// Replace the chat pane with one that keeps a margin. CI type-checks this file against yuke.d.ts.
import { plugins } from "yuke";
import { Session } from "yuke:session";
import { ChatView, ChatSurface } from "yuke:chat";

class RoomyChat extends ChatView {
  /** @param {{ x: number, y: number, w: number, h: number }} bounds */
  layout(bounds) {
    super.layout({ ...bounds, x: bounds.x + 2, w: Math.max(0, bounds.w - 4) });
  }
}

// The surface keeps `render` and `refresh`, so every transcript renderer still reaches the new panes.
class RoomySurface extends ChatSurface {
  /** @param {Session} [session] */
  create(session = new Session()) {
    const view = new RoomyChat(session);
    session.reload([view]);
    return view;
  }
}

plugins.dispose("chat");
plugins.use({
  name: "roomy-chat",
  apply(ctx) {
    ctx.provide("chat", { bindTo: (block) => new RoomySurface(block) });
  },
});
