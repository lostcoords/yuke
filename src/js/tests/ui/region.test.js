import { check } from "yuke:test";
import { root, Node, context } from "yuke:core";
import { ChatView } from "yuke:chat-view";
const key = (code, char) => ({ type: "key", code: code || "char", char: char || "", text: char || "", event: "press", mods: 0 });

const v = new ChatView({ textOf: () => "" });
root.setRoot(Node.leaf(v));
root.focusView(v);
// Count where each key lands, which is the routing contract itself.
let toC = 0;
const rc = v.composer.onKey.bind(v.composer);
v.composer.onKey = (ev) => { toC++; return rc(ev); };

check("default-region", v.focus === "composer");
// The region is an atom below `chat`, so a binding on it outranks one on the pane.
check("stack-composer", context.stack().join(",") === "root,chat,composer");

// The composer takes a printable key.
v.onKey(key("char", "a"));
check("printable-reaches-composer", toC === 1);

// A key the composer declines leaves the pane, so a nav binding can scroll while you type.
check("composer-decline-leaves-pane", v.onKey(key("page_up")) === false && toC === 2);

// The pane offers the transcript pager whichever region reads the keyboard.
check("nav-target", v.navTarget() === v.transcript.pager);

// A focused transcript reads nothing here, because the keymap navigates it.
v.focusRegion("transcript");
check("stack-transcript", context.stack().join(",") === "root,chat,transcript");
const before = v.composer.input.text;
check("transcript-owns", v.onKey(key("char", "b")) === false && toC === 2);
check("transcript-blocks-composer", v.composer.input.text === before);

// The caret belongs to the focused region. A stub stands in for a laid-out composer.
v.composer.cursor = () => ({ x: 1, y: 2, visible: true });
check("caret-hidden", v.cursor() === null);
v.focusRegion("composer");
check("composer-caret-restored", (v.cursor() || {}).x === 1);

// A pane focus returns the keyboard to the composer.
v.focusRegion("transcript");
v.onFocus();
check("pane-focus-resets", v.focus === "composer");

let threw = 0;
try { v.focusRegion("sessions"); } catch (e) { if (e instanceof TypeError) threw = 1; }
check("reject-region", threw === 1 && v.focus === "composer");

// A new tree runs `onFocus`, so a remounted pane starts in the composer.
v.focusRegion("transcript");
root.setRoot(Node.leaf(v));
check("remount-resets", v.focus === "composer");
