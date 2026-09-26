import { check } from "yuke:internal/test";
import { root } from "yuke:internal/core";
import { plugins, services } from "yuke:internal/ext";
import { tui, tuiPlugin } from "yuke:internal/tui";
import { chatPlugin, currentChat } from "yuke:internal/chat";
import { shell } from "yuke:internal/shell";

// The old block leaves before the new one starts, so a plugin the old block started is free for the new block.
let starts = 0;
const child = { name: "inner", apply() { starts++; } };
plugins.use({ name: "outer", apply: (ctx) => { ctx.inject(["gate"], (c) => { c.use(child); }); } });
services.provide("gate", 1);
services.provide("gate", 2);
check("child-restarts", starts === 2 && plugins.names().includes("inner"));

// A new terminal provider rebuilds the chat and the shell; the current chat is the new pane.
plugins.use(tuiPlugin);
plugins.use(chatPlugin);
plugins.use(shell);
check("chat-current", currentChat() !== null && currentChat() === root.active);
services.provide("tui", { bindTo: tui.bindTo });
check("chat-current-after-rebuild", currentChat() !== null && currentChat() === root.active);
