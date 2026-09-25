import { check } from "yuke:internal/test";
import { root, Node, View } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { ChatView } from "yuke:internal/chat-view";
import { composerVim, setComposerMode } from "yuke:internal/composer-vim";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);

let seen = 0;
class Side extends View {
  contexts() { return ["side"]; }
  draw() {}
  onKey(ev) { seen++; return true; }
}
const v = new ChatView({});
const side = new Side();
root.setRoot(Node.branch("row", Node.leaf(side), Node.leaf(v), 0.3));
root.focusView(v);
const off = plugins.use(composerVim);
const t = v.composer.input;
const key = (ch) => ({ type: "key", code: "char", char: ch, text: ch, event: "press", mods: 0 });
const press = (str) => { for (const ch of str) root.onEvent(key(ch)); };

t.setText("abcd");
setComposerMode(v.composer, "normal");
// Put the caret on a character, because "x" past the last one deletes nothing.
press("$");

// The chat holds focus, so the route sends "x" to the binding and the composer edits.
let before = t.text;
press("x");
check("chat-edits", t.text !== before);
check("chat-keeps-side", seen === 0);

// The side pane holds focus, so the route no longer matches and the pane reads the key.
root.focusView(side);
before = t.text;
press("x");
check("side-reads", seen === 1);
check("side-leaves-composer", t.text === before);

// Focus returns to the chat and the route matches again.
root.focusView(v);
before = t.text;
press("x");
check("chat-again", t.text !== before);
check("side-untouched", seen === 1);

off.dispose();
