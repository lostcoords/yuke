import { equal } from "yuke:test";
import { term } from "yuke:term";
import { root, Node, keymap } from "yuke:core";
import { plugins } from "yuke:ext";
import { ChatView } from "yuke:chat-view";
import { composerVim, setComposerMode, composerMode } from "yuke:composer-vim";
import { transcriptVim } from "yuke:transcript-vim";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
const key = (char) => ({ type: "key", code: "char", char: char, text: char, event: "press", mods: 0 });
const body = { a1: "alpha bravo charlie\nsecond line here\nthird line xx" };

const run = (order) => {
  const v = new ChatView({ textOf: (id) => body[id] || "" });
  v.transcript.setOutline([{ id: "a1", type: "assistant" }], null);
  root.setRoot(Node.leaf(v));
  root.focusView(v);
  v.rect = { x: 0, y: 0, w: 24, h: 18 }; v.layout(v.rect);
  term.beginFrame(); v.draw(true); term.endFrame();
  const offs = order === "composer-first"
    ? [plugins.use(composerVim), plugins.use(transcriptVim)]
    : [plugins.use(transcriptVim), plugins.use(composerVim)];
  v.composer.input.setText("hello\nworld");
  setComposerMode(v.composer, "normal");
  v.focusRegion("transcript");
  // The composer stays in normal mode, so both layers really are live.
  const both = composerMode(v.composer) === "normal";
  const c0 = v.cursor();
  const caret0 = v.composer.input.caret;
  root.onEvent(key("j"));
  const movedTranscript = !!(v.cursor() && c0 && v.cursor().y !== c0.y);
  const movedComposer = v.composer.input.caret !== caret0;
  // An unscoped nav binding loses to the deeper vim context while the motion can still move.
  root.onEvent(key("k"));
  root.onEvent(key("k"));
  let bare = 0;
  const offBare = keymap.add({ j: () => { bare++; return true; } });
  const yTop = v.cursor() ? v.cursor().y : -1;
  root.onEvent(key("j"));
  const bareLost = bare === 0 && !!v.cursor() && v.cursor().y !== yTop;
  offBare();
  // A composer binding must not fire at all while the transcript holds the region.
  root.onEvent(key("i"));
  const leaked = composerMode(v.composer) !== "normal";
  // Back in the composer the same key belongs to the other layer again.
  v.focusRegion("composer");
  const caret1 = v.composer.input.caret;
  root.onEvent(key("j"));
  const composerBack = v.composer.input.caret !== caret1;
  // Insert mode must still type, so no transcript binding may own the whole pane.
  setComposerMode(v.composer, "insert");
  const len0 = v.composer.input.text.length;
  root.onEvent(key("h"));
  const typed = v.composer.input.text.length === len0 + 1;
  for (const o of offs) o();
  if (!both) return "not-both";
  if (!bareLost) return "unscoped-binding-won";
  if (leaked) return "composer-leaked";
  if (!typed) return "typing-broken";
  if (!composerBack) return "composer-dead";
  return movedTranscript && !movedComposer ? "transcript" : movedComposer ? "composer" : "neither";
};

for (const order of ["composer-first", "transcript-first"]) {
  equal(run(order), "transcript");
}
