import { Chat } from "yuke:chat";
import { client } from "yuke:client";
globalThis.closes = 0;
globalThis.sends = 0;
client.sessionCreate = (params) => {
  globalThis.firstInput = params.initial_input.content[0].text;
  return new Promise(resolve => { globalThis.accept = resolve; });
};
client.sessionClose = () => { globalThis.closes++; };
client.sessionSendInput = async () => { globalThis.sends++; };
globalThis.chat = new Chat();
globalThis.submitted = globalThis.chat.startChat("first task");
globalThis.chat.newChat();
globalThis.accept({ session: { id: "01".repeat(16) }, input: { type: "started", input_id: 1, run_id: 1 } });
