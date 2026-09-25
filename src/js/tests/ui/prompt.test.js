import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { root, Node } from "yuke:internal/core";
import { plugins, services } from "yuke:internal/ext";
import { Session, chatPlugin } from "yuke:internal/chat";
import { composerVim } from "yuke:internal/composer-vim";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
// The chat plugin tracks the current chat, which the vim layers and the chat commands read.
plugins.use(chatPlugin);
const v = new ChatView(new Session());
root.setRoot(Node.leaf(v));
root.focusView(v);

const own = v.composer._prompt();
// The layer starts in normal mode, so the glyph changes as soon as it loads.
const off = plugins.use(composerVim);
const vim = services.get("composer-vim");
check("normal-glyph", v.composer._prompt() === "▪ " && own !== "▪ ");
vim.setMode(v.composer, "insert");
check("insert-keeps-own", v.composer._prompt() === own);
vim.setMode(v.composer, "normal");
check("normal-again", v.composer._prompt() === "▪ ");

// The unload drops every mode, so a pane without focus also returns to insert on the next load.
const side = new ChatView(new Session());
vim.setMode(side.composer, "normal");
off.dispose();
check("unload-restores", v.composer._prompt() === own);
const again = plugins.use(composerVim);
check("reload-forgets", services.get("composer-vim").mode(side.composer) === "insert");
again.dispose();
