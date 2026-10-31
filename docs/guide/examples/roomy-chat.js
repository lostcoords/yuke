// A chat pane with a margin, in place of the bundled `chat` plugin. CI type-checks this file against yuke.d.ts.
// config.json: { "disable": ["chat"], "plugins": ["./roomy-chat"] }
// plugin.json: {"name": "roomy-chat", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"], "provides": ["chat"]}}}
/** @import { Context } from "yuke" */
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

/** @param {Context} ctx */
export default function (ctx) {
  ctx.provide("chat", { bindTo: (/** @type {Context} */ user) => new RoomySurface(user) });
}
