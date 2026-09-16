import { root, Node } from "yuke:core";
import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { Chat } from "yuke:chat";
import { openAgents } from "yuke:agents-ui";
plugins.use(tuiPlugin);
plugins.use({ name: "overflow-test", apply(ctx) {
  ctx.inject(["tui"], ctx => { (async () => {
    const chat = new Chat();
    root.setRoot(Node.leaf(chat.view)); root.focusView(chat.view);
    chat.sessionId = "01".repeat(16);
    globalThis.picker = await openAgents(ctx, chat.sessionId);
    globalThis.chat = chat;
    result = "ready";
  })().catch(e => result = e.stack || e.message); });
} });
