import { textParts } from "yuke:internal/test";
import { Session } from "yuke:internal/session";
import { term } from "yuke:internal/native/term";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";
import { ChatView } from "yuke:internal/chat-view";

registerRender(defaultRender);
const t = new Transcript({ partsOf: textParts(() => "**hi** there") });
t.setOutline([{ id: "a1", type: "assistant" }], null);
term.beginFrame();
t.draw({ x: 0, y: 0, w: 24, h: 6 });
term.endFrame();
// The pane takes its status line from the caller, so the kit holds no app state.
const v = new ChatView(new Session());
v.transcript.partsOf = textParts(() => "body");
v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
v.rect = { x: 0, y: 0, w: 24, h: 6 }; v.layout(v.rect);
term.beginFrame();
v.draw(true);
term.endFrame();
