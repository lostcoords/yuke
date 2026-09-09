import { check } from "yuke:test";
import { term } from "yuke:term";
import { root, Node } from "yuke:core";
import { plugins } from "yuke:ext";
import { Transcript } from "yuke:transcript";
import { ChatView } from "yuke:chat-view";
import { transcriptVim } from "yuke:transcript-vim";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
const rowsGroup = (rs, group) => rs.some((r) => (r.segments || []).some((sg) => sg.group === group) || r.group === group);
const markerOf = (rs) => ((rs.find((r) => r.kind === "tool-header") || {}).marker || "").trimStart();
const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });
const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: "", event: "press", mods: 0 });

const parts = {
  done: [{ type: "tool", id: 0, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "alpha\\nbeta", duration_ms: 12 } }],
  run: [{ type: "tool", id: 0, name: "exec", arguments: '{"command":"zig build test"}', state: { type: "running", started_at_ms: 1, output: "compiling" } }],
  err: [{ type: "tool", id: 1, name: "edit", arguments: '{"path":"b.zig"}', state: { type: "error", error: "no match", duration_ms: 3 } }],
  mix: [{ type: "text", id: 0, text: "**hi** there" }, { type: "tool", id: 1, name: "read", arguments: '{"path":"c.zig"}', state: { type: "completed", output: "ok", duration_ms: 1 } }],
  diff: [{ type: "tool", id: 0, name: "edit", arguments: '{"path":"d.zig"}', state: { type: "completed", output: "ok", duration_ms: 2, view: [{ type: "diff", files: [{ path: "d.zig", hunks: [{ old_start: 1, old_lines: 1, new_start: 1, new_lines: 1, lines: ["-old", "+new"] }] }] }] } }],
};
const t = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
t.setOutline([{ id: "done", type: "assistant" }, { id: "b1", type: "user" }, { id: "run", type: "assistant" }, { id: "b2", type: "user" }, { id: "err", type: "assistant" }], null);
const paint = (h) => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: h || 12 }); term.endFrame(); };
paint();
t.pager.toTop();
paint();

const done = t.rows(40, 0, 4);
check("done-name", rowsHave(done, "read"));
check("done-path", rowsHave(done, "a.zig"));
check("done-state", rowsHave(done, "done"));
check("done-collapsed", markerOf(done) === "└─" && !rowsHave(done, "alpha"));

const runStart = t._globalRow({ id: "run", row: 0, col: 0 });
const run = t.rows(40, runStart, 6);
check("run-name", rowsHave(run, "exec"));
check("run-expanded", markerOf(run) === "└─" && rowsHave(run, "compiling"));

const errStart = t._globalRow({ id: "err", row: 0, col: 0 });
const err = t.rows(40, errStart, 6);
check("err-expanded", rowsHave(err, "no match") && rowsGroup(err, "TxToolError"));

// A click on a collapsed header expands it. A drag does not.
t.onMouse(at(6, 1, "press"));
t.onMouse(at(6, 1, "release"));
const doneOpen = t.rows(40, 0, 6);
check("click-open", markerOf(doneOpen) === "└─" && rowsHave(doneOpen, "alpha"));
t.onMouse(at(6, 2, "press"));
t.onMouse(at(6, 2, "release"));
check("body-opens-details", root.overlays.length === 1 && root.overlays[0].content.sections[1].text === "alpha\\nbeta");
root.popOverlay(root.overlays[0]);
t.onMouse(at(6, 1, "press"));
t.onMouse(at(8, 1, "drag"));
t.onMouse(at(8, 1, "release"));
check("drag-keeps", rowsHave(t.rows(40, 0, 6), "alpha"));
t.onMouse(at(6, 1, "press"));
t.onMouse(at(6, 1, "release"));
check("click-close", !rowsHave(t.rows(40, 0, 6), "alpha"));

const mix = new Transcript({ textOf: (id) => (id === "mix" ? "**hi** there" : ""), partsOf: (id) => parts[id] || [] });
mix.setOutline([{ id: "mix", type: "assistant" }], null);
term.beginFrame(); mix.draw({ x: 0, y: 0, w: 40, h: 8 }); term.endFrame();
const mixRows = mix.rows(40, 0, 8);
check("mix-text", rowsHave(mixRows, "hi") && rowsHave(mixRows, "there"));
check("mix-tool", rowsHave(mixRows, "read") && rowsHave(mixRows, "c.zig"));
const srcEnd = mix._sourceOf("mix").length;
mix.select(mix.posAtSource("mix", 0), mix.posAtSource("mix", srcEnd));
const src = mix.selectedSource();
check("mix-source-md", src.indexOf("hi") >= 0 && src.indexOf("there") >= 0);
check("mix-source-tool", src.indexOf("read") >= 0 && src.indexOf("c.zig") >= 0);

const dt = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
dt.setOutline([{ id: "diff", type: "assistant" }], null);
dt.togglePart("diff", 0);
const diffRows = dt.rows(40, 0, 10);
check("diff-path", rowsHave(diffRows, "d.zig"));
check("diff-del", rowsHave(diffRows, "-old") && rowsGroup(diffRows, "TxToolDel"));
check("diff-add", rowsHave(diffRows, "+new") && rowsGroup(diffRows, "TxToolAdd"));

const v = new ChatView({ textOf: () => "", partsOf: (id) => parts[id] || [] });
v.transcript.setOutline([{ id: "done", type: "assistant" }], null);
root.setRoot(Node.leaf(v));
v.rect = { x: 0, y: 0, w: 40, h: 12 }; v.layout(v.rect);
const vpaint = () => { term.beginFrame(); v.draw(true); term.endFrame(); };
vpaint();
plugins.use(transcriptVim);
v.focusRegion("transcript");
vpaint();
check("enter-closed", !rowsHave(v.transcript.rows(40, 0, 4), "alpha"));
root.onEvent(key("enter"));
check("enter-preview", root.overlays.length === 0 && rowsHave(v.transcript.rows(40, 0, 8), "alpha"));
root.onEvent(key("down"));
root.onEvent(key("enter"));
check("enter-details", root.overlays.length === 1 && root.overlays[0].content.sections[0].text.indexOf("a.zig") >= 0 && root.overlays[0].content.sections[1].text === "alpha\\nbeta");
root.onEvent(key("esc"));
check("details-close", root.overlays.length === 0 && rowsHave(v.transcript.rows(40, 0, 8), "alpha"));
const vr = v.transcript.pager.rect();
v.onMouse({ type: "mouse", col: vr.x + 6, row: vr.y + 1, button: "left", event: "press", mods: 0 });
v.onMouse({ type: "mouse", col: vr.x + 6, row: vr.y + 1, button: "left", event: "release", mods: 0 });
check("plugin-click-close", !rowsHave(v.transcript.rows(40, 0, 8), "alpha"));

const longOut = Array.from({ length: 80 }, (_, i) => "line" + i).join("\n");
parts.long = [{ type: "tool", id: 0, name: "exec", arguments: '{"command":"seq"}', state: { type: "completed", output: longOut, duration_ms: 1 } }];
const longT = new Transcript({ textOf: () => "", partsOf: (id) => parts[id] || [] });
longT.setOutline([{ id: "long", type: "assistant" }], null);
term.beginFrame(); longT.draw({ x: 0, y: 0, w: 40, h: 4 }); term.endFrame();
longT.onMouse(at(6, 1, "press"));
longT.onMouse(at(6, 1, "release"));
term.beginFrame(); longT.draw({ x: 0, y: 0, w: 40, h: 4 }); term.endFrame();
const headerAt = longT.screenAt({ id: "long", row: 0, col: 0 });
check("header-on-screen", !!headerAt && headerAt.y >= 0 && headerAt.y < 4);
check("preview-cap", longT.rowCountOf("long") === 8 && longT.rows(40, 0, 20).filter((r) => r.kind === "tool-body").length === 3);
check("unfold-unstuck", longT.pager.stuck === false);

parts.thought = [{ type: "reasoning", id: 0, text: "one two three four five six seven eight" }];
const thought = new Transcript({ partsOf: (id) => parts[id] || [] });
thought.setOutline([], { id: "thought", type: "assistant" });
term.beginFrame(); thought.draw({ x: 0, y: 0, w: 20, h: 8 }); term.endFrame();
thought.onMouse(at(6, 2, "press"));
thought.onMouse(at(6, 2, "release"));
check("reasoning-body-details", root.overlays.length === 1 && root.overlays[0].content.sections[0].text === parts.thought[0].text);
root.popOverlay(root.overlays[0]);
