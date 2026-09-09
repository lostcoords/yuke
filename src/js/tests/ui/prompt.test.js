import { check } from "yuke:test";
import { root, Node } from "yuke:core";
import { plugins } from "yuke:ext";
import { ChatView } from "yuke:chat-view";
import { composerVim, setComposerMode } from "yuke:composer-vim";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
const v = new ChatView({ textOf: () => "" });
root.setRoot(Node.leaf(v));
root.focusView(v);

const own = v.composer._prompt();
// The layer starts in normal mode, so the glyph changes as soon as it loads.
const off = plugins.use(composerVim);
check("normal-glyph", v.composer._prompt() === "▪ " && own !== "▪ ");
setComposerMode(v.composer, "insert");
check("insert-keeps-own", v.composer._prompt() === own);
setComposerMode(v.composer, "normal");
check("normal-again", v.composer._prompt() === "▪ ");

// The unload removes the provider, so normal mode no longer changes the glyph.
off();
setComposerMode(v.composer, "normal");
check("unload-restores", v.composer._prompt() === own);
