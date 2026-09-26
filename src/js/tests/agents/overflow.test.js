import { root, Node } from "yuke:internal/core";
import { ChatView } from "yuke:internal/chat-view";
import { plugins } from "yuke:internal/ext";
import { Session } from "yuke:internal/session";
import { openAgents } from "yuke:internal/agents-ui";
plugins.use({ name: "overflow-test", apply(ctx) {
  ctx.inject(["tui"], ctx => { (async () => {
    const chat = new ChatView(new Session());
    root.setRoot(Node.leaf(chat)); root.focusView(chat);
    chat.session.sessionId = "01".repeat(16);
    globalThis.picker = await openAgents(ctx, chat.session.sessionId);
    globalThis.chat = chat;
    result = "ready";
  })().catch(e => result = e.stack || e.message); });
} });
