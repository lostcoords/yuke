import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { root, Node } from "yuke:internal/core";
import { plugins, services } from "yuke:internal/ext";
import { chatPlugin } from "yuke:internal/chat";
import { Session, sessionsPlugin } from "yuke:internal/session";
import { composerVim } from "yuke:internal/composer-vim";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
// The chat plugin tracks the current chat, which the vim layers and the chat commands read.
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
const v = new ChatView(new Session());
root.setRoot(Node.leaf(v));
root.focusView(v);

// A layout pass reads the prompt, so each check runs one.
const prompt = () => (v.composer.height(20), v.composer._promptText);
const own = prompt();
// The layer starts in normal mode, so the glyph changes as soon as it loads.
const off = plugins.use(composerVim);
const vim = services.get("composer-vim");
check("normal-glyph", prompt() === "▪ " && own !== "▪ ");
vim.setMode(v.composer, "insert");
check("insert-keeps-own", prompt() === own);
// A mode change asks for a layout, because only a layout reads the new glyph.
root._layoutDirty = false;
vim.setMode(v.composer, "normal");
check("normal-again", root._layoutDirty && prompt() === "▪ ");

// The unload drops every mode, so a pane without focus also returns to insert on the next load.
const side = new ChatView(new Session());
vim.setMode(side.composer, "normal");
root._layoutDirty = false;
off.dispose();
// An unload can come from a timer, so it asks for the layout that reads the restored glyph.
check("unload-restores", root._layoutDirty && prompt() === own);
const again = plugins.use(composerVim);
check("reload-forgets", services.get("composer-vim").mode(side.composer) === "insert");
again.dispose();
