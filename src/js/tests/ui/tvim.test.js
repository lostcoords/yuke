import { check } from "yuke:test";
import { term } from "yuke:term";
import { root, Node, keymap } from "yuke:core";
import { plugins } from "yuke:ext";
import { ChatView } from "yuke:chat-view";
import { transcriptVim } from "yuke:transcript-vim";
import { register } from "yuke:vim";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: "", event: "press", mods: 0 });

// The shell is not loaded, so a yank must reach the clipboard through the core alone.
const body = { a1: "alpha **bravo** charlie delta" };
let copied = null;
term.copy = (x) => { copied = x; return x.length; };
const v = new ChatView({ textOf: (id) => body[id] || "" });
v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
root.setRoot(Node.leaf(v));
v.rect = { x: 0, y: 0, w: 24, h: 18 }; v.layout(v.rect);
const paint = () => { term.beginFrame(); v.draw(true); term.endFrame(); };
paint();

// Without the plugin the composer owns the caret and a bare key types.
const composerCaret = v.cursor();
check("composer-caret", composerCaret && composerCaret.y === v.composer.rect.y);

const off = plugins.use(transcriptVim);
// The pane takes no cursor until the focus moves, so typing still works.
check("still-composer", v.cursor().y === v.composer.rect.y);
v.focusRegion("transcript");
const c0 = v.cursor();
check("transcript-caret", c0 && c0.visible && c0.y < v.composer.rect.y);

// A motion moves the caret one cell, and it never reaches the composer text.
const before = v.composer.input.text;
root.onEvent(key("char", "l"));
const c1 = v.cursor();
check("moved-right", c1.x === c0.x + 1);
check("transcript-blocks-composer", v.composer.input.text === before);
root.onEvent(key("char", "h"));
check("moved-left", v.cursor().x === c0.x);

// "$" goes to the row end and "0" back to its start.
root.onEvent(key("char", "$"));
check("row-end", v.cursor().x > c0.x);
root.onEvent(key("char", "0"));
check("row-start", v.cursor().x === c0.x);

// The transcript cursor also stays on a character.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
root.onEvent(key("char", "$"));
check("transcript-dollar", v.cursor().x === 2 + v.transcript.rowTextAt("a1", 0).length - 1);

// "gg" reaches the first row and "G" the last. A shifted letter keeps its case.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
const top = v.cursor().y;
root.onEvent(key("char", "G"));
check("G-moves", v.cursor().y > top);
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
check("gg-returns", v.cursor().y === top);

// An unbound key still reaches the global keymap.
let global = 0;
const offZ = keymap.add({ z: () => { global++; } });
root.onEvent(key("char", "z"));
check("global-keymap-fallback", global === 1 && v.composer.input.text === before);
offZ();

// A click places the cursor on the row it landed on and takes the region.
const r = v.transcript.pager.rect();
root.onEvent(key("char", "G"));
const clickBase = v.cursor().y;
v.focusRegion("composer");
const press = (row) => v.onMouse({ type: "mouse", col: r.x + 4, row, button: "left", event: "press", mods: 0 });
press(r.y);
check("click-takes-region", v.focus === "transcript");
check("click-moves-cursor", !!v.cursor() && v.cursor().y === r.y && clickBase !== r.y);

// A press below the transcript hands the region back to the composer.
press(v.composer.rect.y);
check("click-outside-releases", v.focus === "composer");
v.focusRegion("transcript");

// "v" starts a selection that the motions extend. Vim visual holds both ends, so the
// character under the cursor stays inside.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
root.onEvent(key("char", "v"));
root.onEvent(key("char", "l"));
root.onEvent(key("char", "l"));
check("visual-inclusive", v.transcript.selectedText() === "alp");

// "o" puts the cursor on the other end, so the far end grows instead.
const far = v.cursor().x;
root.onEvent(key("char", "o"));
check("swap-ends", v.cursor().x < far);
root.onEvent(key("char", "o"));
check("swap-back", v.cursor().x === far);

// "y" copies the rendered text and drops the selection.
root.onEvent(key("char", "y"));
check("yank-visual", copied === "alp" && v.transcript.selection === null);

// "y" alone waits for a second "y", because a motion can follow it.
copied = null;
root.onEvent(key("char", "y"));
check("yank-pending", copied === null);
root.onEvent(key("char", "y"));
check("yank-row", copied === "alpha bravo charlie");

// "gy" copies the markdown source, so the markup between the ends survives.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "y"));
check("yank-source", copied === "alpha **bravo** charlie");

// "Y" takes whole rows, so the register is linewise even inside visual mode.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
root.onEvent(key("char", "v"));
root.onEvent(key("char", "l"));
root.onEvent(key("char", "Y"));
check("visual-Y-linewise", register.linewise === true && copied === "alpha bravo charlie");

// "}" and "{" step by markdown block.
body.a2 = "# Head\n\npara text\n\n- item";
v.transcript.setOutline([{ id: "a1", type: "assistant" }, { id: "a2", type: "assistant" }], null);
paint();
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
const seen = [];
for (let i = 0; i < 4; i++) { root.onEvent(key("char", "}")); seen.push(v.cursor().y); }
check("block-forward", seen.length === 4 && seen[0] < seen[1] && seen[1] < seen[2]);
const back = seen[seen.length - 1];
root.onEvent(key("char", "{"));
check("block-back", v.cursor().y < back);

// A rewrap moves every row index, so the cursor holds its source character instead.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
// Row 1 holds different words at each width, so its row index alone is not the same text.
root.onEvent(key("char", "j"));
const srcAt = () => v.transcript.sourceAt(v.transcript.posAt(v.cursor().x, v.cursor().y, false));
const srcBefore = srcAt();
v.rect = { x: 0, y: 0, w: 14, h: 18 }; v.layout(v.rect);
paint();
const srcAfter = srcAt();
check("cursor-survives-rewrap", srcBefore >= 0 && srcAfter === srcBefore);
v.rect = { x: 0, y: 0, w: 24, h: 18 }; v.layout(v.rect);
paint();

// A region change clears visual mode and drops its selection.
root.onEvent(key("char", "g"));
root.onEvent(key("char", "g"));
root.onEvent(key("char", "v"));
root.onEvent(key("char", "l"));
check("visual-selects", v.transcript.selection !== null);
v.focusRegion("composer");
check("region-clears-selection", v.transcript.selection === null);
v.focusRegion("transcript");
root.onEvent(key("char", "l"));
check("region-clears-visual", v.transcript.selection === null);

// A focus jump from another pane hands the keyboard back to the composer.
const side = { name: "sessions", layout() {}, draw() {}, onKey() { return false; } };
root.setRoot(Node.branch("row", Node.leaf(side), Node.leaf(v), 0.3));
root.focusView(v);
paint();
v.focusRegion("transcript");
check("region-transcript", v.cursor() && v.cursor().y < v.composer.rect.y);
root.focusView(side);
root.focusView(v);
check("jump-composer", v.cursor() && v.cursor().y === v.composer.rect.y);

// An unload returns the region and the caret to the composer.
v.focusRegion("transcript");
off();
check("unload-region", v.focus === "composer");
check("unload-restores", (v.cursor() || {}).y === v.composer.rect.y);
root.onEvent(key("char", "x"));
check("unload-restores-typing", v.composer.input.text === before + "x");
check("unload-consumes", v.onKey(key("char", "y")) === true && v.composer.input.text === before + "xy");
