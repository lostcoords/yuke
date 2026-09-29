// Replace the chat pane with one that keeps a margin. CI type-checks this file against yuke.d.ts.
import { plugins } from "yuke";
import { Session } from "yuke:session";
import { ChatView, registerLabels } from "yuke:chat";

class RoomyChat extends ChatView {
  /** @param {{ x: number, y: number, w: number, h: number }} bounds */
  layout(bounds) {
    super.layout({ ...bounds, x: bounds.x + 2, w: Math.max(0, bounds.w - 4) });
  }
}

plugins.dispose("chat");
plugins.use({
  name: "roomy-chat",
  apply(ctx) {
    ctx.provide("chat", {
      bindTo: (block) => ({
        create: (session = new Session()) => new RoomyChat(session),
        labels: (entries) => block.effect(() => registerLabels(entries)),
      }),
    });
  },
});
