import { root, Node } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { Chat } from "yuke:internal/chat";
import { openAgents } from "yuke:internal/agents-ui";
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
