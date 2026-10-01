import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { term } from "yuke:internal/native/term";
import { root, Node } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { Session } from "yuke:internal/session";
import { transcriptVim } from "yuke:internal/transcript-vim";
import { tuiPlugin } from "yuke:internal/tui";
import { registerRender, toggleExpandAll } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";

registerRender(defaultRender);
plugins.use(tuiPlugin);
plugins.use(transcriptVim);
const lines = (tag, n) => Array.from({ length: n }, (_, i) => tag + "-" + i).join("\n");
const exec = (id, tag) => ({ type: "tool", id, name: "exec", arguments: '{"command":"' + tag + '"}', state: { type: "completed", output: lines(tag, 12) } });
// Two blocks open above the cursor and one below it, so neither the top row nor the tail keeps the cursor row.
const parts = { m: [exec(1, "above"), exec(2, "near"), exec(3, "cursor"), { type: "text", id: 4, text: "after the tools" }] };
const v = new ChatView(new Session());
const t = v.transcript;
t.partsOf = (id) => parts[id] || [];
t.setOutline([{ id: "m", type: "assistant" }], null);
root.setRoot(Node.leaf(v));
v.rect = { x: 0, y: 0, w: 40, h: 18 }; v.layout(v.rect);
// A frame reads the cursor after the draw, as `root` does. That read moves the vim cursor back to the cursor text.
const paint = () => { term.beginFrame(); v.draw(true); v.cursor(); term.endFrame(); };
const press = (row) => v.onMouse({ type: "mouse", col: 0, row, button: "left", event: "press", mods: 0 });
paint();

// A click puts the vim cursor on the last header, under the top row of the pane at the tail.
const header = t.partHeader("m", 3);
const y = t.screenAt(header)?.y ?? -1;
check("header-under-top", t.pager.stuck && y > (t.pager.rect()?.y ?? 0));
press(y);
paint();
check("cursor-on-header", v.focus === "transcript" && v.cursor()?.y === y);

// ctrl+o opens every block. The cursor text keeps the same screen row, at the tail too.
toggleExpandAll();
paint();
const c = v.cursor();
const at = c ? t.posAt(c.x, c.y, false) : null;
check("cursor-keeps-row", c?.y === y && at != null && t.rowTextAt(at.id, at.row) === "$ cursor");

// The composer focus leaves no cursor in the transcript, so an open at the tail follows the tail.
toggleExpandAll();
paint();
v.focusRegion("composer");
t.pager.toBottom();
toggleExpandAll();
paint();
check("tail-follows", t.pager.stuck && t.pager.atBottom());
