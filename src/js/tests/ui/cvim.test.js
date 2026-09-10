import { check } from "yuke:test";
import { root, Node, View, keymap } from "yuke:core";
import { plugins } from "yuke:ext";
import { ChatView } from "yuke:chat-view";
import { composerVim, setComposerMode, composerMode } from "yuke:composer-vim";
import { register } from "yuke:vim";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);

const v = new ChatView({ textOf: () => "" });
root.setRoot(Node.leaf(v));
root.focusView(v);
const off = plugins.use(composerVim);
const t = v.composer.input;
const key = (ch) => ({ type: "key", code: "char", char: ch, text: ch, event: "press", mods: 0 });
// The keys go through the real dispatch, so the bindings and the context both run.
const press = (str) => { for (const ch of str) root.onEvent(key(ch)); };

t.setText("alpha bravo charlie");
setComposerMode(v.composer, "normal");
press("$");
// Normal mode holds the caret on a character, so it never sits past the last one.
check("dollar", t.caret === 18);
press("bb");
check("back-word", t.caret === 6);
press("w");
check("fwd-word", t.caret === 12);
press("e");
check("word-end", t.caret === 18);
press("0");
check("zero", t.caret === 0);

// A shifted letter keeps its case, so D is not a pending d.
press("$x");
check("x", t.text === "alpha bravo charli" && t.caret === 17);
press("0w");
press("D");
check("D", t.text === "alpha " && register.text === "bravo charli");

// "p" puts the register after the caret.
press("$p");
check("put-char", t.text === "alpha bravo charli");

// "dw" follows vim's word classes and never joins lines.
t.setText("alpha bravo\ncharlie");
setComposerMode(v.composer, "normal");
press("ggdw");
check("dw-word", t.text === "bravo\ncharlie" && t.caret === 0 && register.text === "alpha ");
press("$dw");
check("dw-line-end", t.text === "brav\ncharlie" && register.text === "o");
t.setText("alpha, bravo");
setComposerMode(v.composer, "normal");
press("0dw");
check("dw-punctuation", t.text === ", bravo" && register.text === "alpha");
t.setText("alpha bravo");
setComposerMode(v.composer, "normal");
press("0llldw");
check("dw-inside-word", t.text === "alpbravo" && register.text === "ha ");
t.setText("alpha\n\nbravo");
setComposerMode(v.composer, "normal");
t.caret = 6;
press("dw");
check("dw-empty-line", t.text === "alpha\n\nbravo" && register.text === "ha ");

// "p" leaves the caret on the last character it put.
t.setText("abc");
setComposerMode(v.composer, "normal");
press("gg");
register.set("XY", false);
press("p");
check("put-caret", t.text === "aXYbc" && t.caret === 2);

// "dd" on the last line takes the newline before it, but the register keeps only the body.
t.setText("one\ntwo");
setComposerMode(v.composer, "normal");
press("$dd");
check("dd-last", t.text === "one" && register.text === "two" && register.linewise);
press("p");
check("put-line", t.text === "one\ntwo");

// Normal mode holds the caret on a character after every motion.
v.composer.rect = { x: 0, y: 0, w: 40, h: 3 };
t.setText("abcdef\ntwo");
setComposerMode(v.composer, "normal");
press("gg$j");
check("row-clamp", t.caret === t.text.length - 1);
t.setText("one\n");
setComposerMode(v.composer, "normal");
press("G");
check("trailing-newline", t.caret === 2);

// "x" never joins two lines, and a blank line keeps the register.
t.setText("a\n\nb");
setComposerMode(v.composer, "normal");
press("gg");
press("jx");
check("x-blank-line", t.text === "a\n\nb");

// An unbound letter inserts nothing in normal mode and runs no command.
t.setText("abc");
setComposerMode(v.composer, "normal");
press("z");
check("swallow", t.text === "abc");
check("named-key-passes", v.composer.onKey({ type: "key", code: "tab", char: "", text: "", event: "press", mods: 0 }) === false);

// The motions run as bindings, so a binding under the same context reaches the same keys.
{
  let hits = 0;
  const off = keymap.add({ z: () => { hits++; return true; } }, "chat && composer_vim == normal");
  t.setText("abc");
  setComposerMode(v.composer, "normal");
  press("z");
  check("normal-uses-keymap", hits === 1);
  off();
}

// An unresolved sequence runs its second stroke on its own rather than dropping it.
{
  t.setText("abc def");
  setComposerMode(v.composer, "normal");
  press("$");
  const at = t.caret;
  press("dh");
  check("operator-fallthrough", t.caret === at - 1 && t.text === "abc def");
}

// Esc reaches its binding while an operator waits, so a mode always has an exit.
{
  setComposerMode(v.composer, "normal");
  press("d");
  check("operator-armed", keymap.pending !== null);
  root.onEvent({ type: "key", code: "esc", char: "", text: "", event: "press", mods: 0 });
  check("operator-esc", keymap.pending === null);
}

// Insert mode still inserts through the real dispatch.
{
  t.setText("");
  setComposerMode(v.composer, "insert");
  press("hi");
  check("insert-inserts", t.text === "hi");
}

// The bindings stay off a pane that is not the chat, even while the chat holds normal mode.
{
  class Side extends View { get name() { return "side"; } draw() {} }
  const side = new Side();
  t.setText("abc");
  setComposerMode(v.composer, "normal");
  root.setRoot(Node.branch("row", Node.leaf(side), Node.leaf(v), 0.5));
  root.focusView(side);
  press("x");
  check("normal-needs-chat", t.text === "abc");
  root.setRoot(Node.leaf(v));
  root.focusView(v);
}

// "i" types again, and an unload leaves the composer plain.
press("i");
check("insert", composerMode(v.composer) === "insert");
setComposerMode(v.composer, "normal");
t.setText("");
off();
check("unloaded", composerMode(v.composer) === "insert");
v.composer.onKey(key("z"));
check("types-after-unload", t.text === "z");
