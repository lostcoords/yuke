import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { root, command } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { client } from "yuke:internal/client";
import { chatPlugin, currentChat, openSession } from "yuke:internal/chat";
import { tuiPlugin } from "yuke:internal/tui";
import { shell } from "yuke:internal/shell";
client.sessionOpen = () => true;
client.sessionClose = () => {};
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [{ id: 1, type: "user" }], active: null });
plugins.use(tuiPlugin);
plugins.use(chatPlugin);
plugins.use(shell);
const panes = () => root.root_node.leaves().map((leaf) => leaf.shape.view);
openSession(root.active, "a");
command.perform("window:split-right");
const [a, b] = panes();
const focused = root.active;

// A new factory swaps the open panes in place: each keeps its session, its history, and the focus.
class Wide extends ChatView {}
const wide = plugins.use({ name: "wide", apply(ctx) { ctx.inject(["chat"], (ctx) => { ctx.chat.view((session) => new Wide(session)); }); } });
const [a2, b2] = panes();
check("swapped", a2 instanceof Wide && b2 instanceof Wide);
check("sessions-kept", a2.session === a.session && a2.session.sessionId === "a" && b2.session === b.session);
check("old-left", !a.session.views.has(a) && a.session.views.size === 1);
check("history", a2.transcript.rowCount(40) > 0);
check("focus-kept", root.active === (focused === b ? b2 : a2) && currentChat() === root.active);
command.perform("window:split-down");
check("new-pane", root.active instanceof Wide);

// The unload swaps them back to the default view.
wide.dispose();
check("restored", panes().every((view) => view instanceof ChatView && !(view instanceof Wide)));
check("restored-session", panes()[0].session.sessionId === "a");
