import { Session, showSession } from "yuke:internal/chat";
import { ChatView } from "yuke:internal/chat-view";
import { client } from "yuke:internal/client";
globalThis.closes = 0;
globalThis.sends = 0;
client.sessionCreate = (params) => {
  globalThis.firstInput = params.initial_input.content[0].text;
  return new Promise(resolve => { globalThis.accept = resolve; });
};
client.sessionClose = () => { globalThis.closes++; };
client.sessionSendInput = async () => { globalThis.sends++; };
globalThis.chat = new ChatView(new Session());
globalThis.submitted = globalThis.chat.session.startChat({ type: "content", content: [{ type: "text", text: "first task" }] }, globalThis.chat.composer);
showSession(globalThis.chat, new Session());
globalThis.accept({ session: { id: "01".repeat(16) }, input: { type: "started", input_id: 1, run_id: 1 } });
