import { check, equal } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { term } from "yuke:internal/native/term";
import { root, Node } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { Transcript, inputSourceLabel, registerRender } from "yuke:internal/transcript";
import { defaultRender, displayCommand, diffRows } from "yuke:internal/transcript-view";
import { chatPlugin } from "yuke:internal/chat";
import { Session, sessionsPlugin } from "yuke:internal/session";
import { transcriptVim } from "yuke:internal/transcript-vim";
import { tuiPlugin } from "yuke:internal/tui";

registerRender(defaultRender);
plugins.use(tuiPlugin);
// The chat plugin tracks the current chat, which the vim layers and the chat commands read.
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
const rowsHave = (rs, want) => rs.some((r) => (r.segments || []).some((sg) => sg.text.indexOf(want) >= 0) || (r.text || "").indexOf(want) >= 0);
const rowsGroup = (rs, group) => rs.some((r) => (r.segments || []).some((sg) => sg.group === group) || r.group === group);
const at = (col, row, event) => ({ type: "mouse", col, row, button: "left", event, mods: 0 });
const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: "", event: "press", mods: 0 });

const parts = {
  done: [{ type: "tool", id: 0, name: "read", arguments: '{"path":"a.zig"}', state: { type: "completed", output: "alpha\\nbeta", duration_ms: 12 } }],
  run: [{ type: "tool", id: 0, name: "exec", arguments: '{"command":"zig build test"}', state: { type: "running", started_at_ms: Date.now() - 1500, output: "compiling" } }],
  err: [{ type: "tool", id: 1, name: "edit", arguments: '{"path":"b.zig"}', state: { type: "error", error: "no match", duration_ms: 3 } }],
  mix: [{ type: "text", id: 0, text: "**hi** there" }, { type: "tool", id: 1, name: "read", arguments: '{"path":"c.zig"}', state: { type: "completed", output: "ok", duration_ms: 1 } }],
  diff: [{ type: "tool", id: 0, name: "edit", arguments: '{"path":"d.zig"}', state: { type: "completed", output: "ok", duration_ms: 2, diff: [{ path: "d.zig", hunks: [{ old_start: 1, old_lines: 1, new_start: 1, new_lines: 1, lines: ["-old", "+new"] }] }] } }],
};
const t = new Transcript({ partsOf: (id) => parts[id] || [] });
t.setOutline([{ id: "done", type: "assistant" }, { id: "b1", type: "user" }, { id: "run", type: "assistant" }, { id: "b2", type: "user" }, { id: "err", type: "assistant" }], null);
const paint = (h) => { term.beginFrame(); t.draw({ x: 0, y: 0, w: 40, h: h || 12 }); term.endFrame(); };
paint();
t.pager.toTop();
paint();

// A folded read shows its header alone; a running command shows the tail of its output; an error shows its text.
const done = t.rows(40, 0, 2);
check("done-header", rowsHave(done, "read") && rowsHave(done, "a.zig") && rowsHave(done, "0.0s") && !rowsHave(done, "alpha") && done[0].header === true);
const run = t.rows(40, t._globalRow({ id: "run", row: 0, col: 0 }), 4);
check("run-preview", rowsHave(run, "$") && rowsHave(run, "zig build test") && rowsHave(run, "1.5s") && rowsHave(run, "compiling") && run[0].bg === "TxToolPendingBg");
const err = t.rows(40, t._globalRow({ id: "err", row: 0, col: 0 }), 4);
check("err-shows", rowsHave(err, "no match") && rowsHave(err, "0.0s") && rowsGroup(err, "TxToolError") && err[0].bg === "TxToolErrorBg");

// A click on any row of a block toggles it. A drag does not.
t.onMouse(at(4, 0, "press"));
t.onMouse(at(4, 0, "release"));
check("click-open", rowsHave(t.rows(40, 0, 4), "alpha"));
t.onMouse(at(4, 0, "press"));
t.onMouse(at(6, 0, "drag"));
t.onMouse(at(6, 0, "release"));
check("drag-keeps", rowsHave(t.rows(40, 0, 4), "alpha"));
t.onMouse(at(4, 1, "press"));
t.onMouse(at(4, 1, "release"));
check("body-click-folds", !rowsHave(t.rows(40, 0, 4), "alpha"));

// Markdown text and a tool block copy their source together.
const mix = new Transcript({ partsOf: (id) => parts[id] || [] });
mix.setOutline([{ id: "mix", type: "assistant" }], null);
mix.rows(40, 0, 8);
const srcEnd = mix._sourceOf("mix").length;
mix.select(mix.posAtSource("mix", 0), mix.posAtSource("mix", srcEnd));
const src = mix.selectedText(true);
equal(src, "hi** there\nread c.zig");

// An edit shows its whole diff while folded.
const dt = new Transcript({ partsOf: (id) => parts[id] || [] });
dt.setOutline([{ id: "diff", type: "assistant" }], null);
const editRows = dt.rows(40, 0, 10);
check("diff", rowsHave(editRows, "-old") && rowsGroup(editRows, "TxDiffDel") && rowsHave(editRows, "+new") && rowsGroup(editRows, "TxDiffAdd") && dt._sourceOf("diff") === "edit d.zig\n-old\n+new");
// A diff the engine cut says so, because an expanded edit shows no more lines.
const cutEdit = { ...parts.diff[0], cut: [{ field: "diff", total: 500 }] };
const ct = new Transcript({ partsOf: () => [cutEdit] });
ct.setOutline([{ id: "cut", type: "assistant" }], null);
check("diff-cut-hint", rowsHave(ct.rows(40, 0, 10), "… (the diff is cut: 500 lines in total)"));
const multiDiff = diffRows([{ path: "one.zig", hunks: [] }, { path: "two.zig", hunks: [] }], 40, 1);
check("multi-diff-paths", rowsHave(multiDiff.rows, "one.zig") && rowsHave(multiDiff.rows, "two.zig") && multiDiff.source === "one.zig\ntwo.zig");
const hunk = (line) => ({ old_start: 1, old_lines: 1, new_start: 1, new_lines: 1, lines: [line] });
check("hunk-separator", diffRows([{ path: "one.zig", hunks: [hunk("-a"), hunk("+b")] }], 40, 1).source === "-a\n…\n+b");

// Enter toggles the block under the transcript cursor.
const v = new ChatView(new Session());
v.transcript.partsOf = (id) => parts[id] || [];
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
check("enter-opens", root.overlays.length === 0 && rowsHave(v.transcript.rows(40, 0, 8), "alpha"));
root.onEvent(key("down"));
root.onEvent(key("enter"));
check("enter-body-folds", !rowsHave(v.transcript.rows(40, 0, 8), "alpha"));

// A long shell output folds to its last five lines, and a click on the tail keeps the header on the screen.
const longOut = Array.from({ length: 80 }, (_, i) => "line" + i).join("\n");
parts.long = [{ type: "tool", id: 0, name: "exec", arguments: '{"command":"seq"}', state: { type: "completed", output: longOut, duration_ms: 1500 } }];
const longT = new Transcript({ partsOf: (id) => parts[id] || [] });
longT.setOutline([{ id: "long", type: "assistant" }], null);
const folded = longT.rows(40, 0, longT.rowCount(40));
check("exec-tail", rowsHave(folded, "earlier lines") && rowsHave(folded, "line75") && rowsHave(folded, "line79") && !rowsHave(folded, "line74") && rowsHave(folded, "1.5s"));
term.beginFrame(); longT.draw({ x: 0, y: 0, w: 40, h: 4 }); term.endFrame();
longT.onMouse(at(4, 0, "press"));
longT.onMouse(at(4, 0, "release"));
term.beginFrame(); longT.draw({ x: 0, y: 0, w: 40, h: 4 }); term.endFrame();
const headerAt = longT.screenAt({ id: "long", row: 0, col: 0 });
check("header-on-screen", !!headerAt && headerAt.y >= 0 && headerAt.y < 4);
check("expanded-all", rowsHave(longT.rows(40, 0, longT.rowCount(40)), "line0") && longT.pager.stuck === false);

// A command header preserves shell context. An open clipped header reveals the original command. An outside path stays absolute.
const command = "# prepare\ncd /tmp/demo-project && MISE_SHELL=bash /usr/bin/zig build test-js # all";
parts.pres = [{ type: "tool", id: 0, name: "exec", arguments: JSON.stringify({ command }), state: { type: "completed", output: "ok", duration_ms: 1 } }];
const pres = new Transcript({ partsOf: (id) => parts[id] || [] });
pres.setOutline([{ id: "pres", type: "assistant" }], null);
check("exec-head", rowsHave(pres.rows(100, 0, 4), displayCommand(command)) && pres._sourceOf("pres") === "$ " + command + "\nok");
pres.togglePart("pres", 0);
const shownCommand = pres.rows(40, 0, pres.rowCount(40));
const commandSource = pres._sourceOf("pres");
check("exec-input", rowsHave(shownCommand, "/usr/bin/zig") && commandSource === "$ " + command + "\nok");
pres.select(pres.posAtSource("pres", 0), pres.posAtSource("pres", commandSource.length));
equal(pres.selectedText(true), commandSource);
parts.unknown = [{ type: "tool", id: 0, name: "mcp_thing", arguments: '{"path":"/tmp/x.txt"}', state: { type: "completed", output: "ok", duration_ms: 1 } }];
const unknown = new Transcript({ partsOf: (id) => parts[id] || [] });
unknown.setOutline([{ id: "unknown", type: "assistant" }], null);
check("fallback-head", rowsHave(unknown.rows(60, 0, 4), "mcp_thing") && rowsHave(unknown.rows(60, 0, 4), "/tmp/x.txt"));

// A plugin renderer stacks on the look: its tool head wins, unrelated raw input drops, a faulty head leaves no rows, and an unload restores the look below.
const owner = plugins.use({ name: "test-head", apply(ctx) {
  ctx.inject(["chat"], (ctx) => { ctx.chat.render({ tools: { exec: () => ({ verb: "run", subject: "custom", input: "unrelated raw input" }) }, sources: { engine_interruption: () => "first" } }); });
} });
const over = new Transcript({ partsOf: (id) => parts[id] || [] });
over.setOutline([{ id: "pres", type: "assistant" }], null);
const overRows = over.rows(60, 0, 4);
check("override-head", rowsHave(overRows, "custom") && rowsHave(overRows, "0.0s") && over._sourceOf("pres") === "run custom\nok");
check("cached-rows-change", rowsHave(pres.rows(60, 0, 4), "custom"));
const faulty = plugins.use({ name: "test-faulty-head", apply(ctx) {
  ctx.inject(["chat"], (ctx) => { ctx.chat.render({ tools: { exec: () => { throw new Error("bad"); } }, sources: { engine_interruption: () => "second" } }); });
} });
owner.dispose();
check("lower-source-leaves", inputSourceLabel({ type: "engine_interruption", run_id: 1, kind: "turn" }) === "second");
check("head-fault-empties", !rowsHave(over.rows(60, 0, 4), "custom") && over.rowCountOf("pres") === 1);
faulty.dispose();
check("source-restores-default", inputSourceLabel({ type: "engine_interruption", run_id: 1, kind: "turn" }) === "Engine notice · run 1 interrupted");
check("head-restores-default", rowsHave(over.rows(60, 0, 4), "$"));
