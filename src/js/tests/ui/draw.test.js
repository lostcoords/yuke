import { term } from "yuke:term";
import { Transcript } from "yuke:transcript";
import { ChatView } from "yuke:chat-view";
const t = new Transcript({ textOf: () => "**hi** there" });
t.setOutline([{ id: "a1", type: "assistant" }], null);
term.beginFrame();
t.draw({ x: 0, y: 0, w: 24, h: 6 });
term.endFrame();
// The pane takes its status line from the caller, so the kit holds no app state.
const v = new ChatView({ textOf: () => "body" });
v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
v.rect = { x: 0, y: 0, w: 24, h: 6 }; v.layout(v.rect);
term.beginFrame();
v.draw(true);
term.endFrame();
