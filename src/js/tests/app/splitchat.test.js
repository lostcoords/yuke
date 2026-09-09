import { check } from "yuke:test";
import { root, Node, events } from "yuke:core";
import { plugins } from "yuke:ext";
import { Chat, chats, chatOf, focusedChat, focusedChatView, chatPlugin } from "yuke:chat";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
plugins.use(chatPlugin);

const a = new Chat();
root.setRoot(Node.leaf(a.view));
root.focusView(a.view);
check("first-is-focused", focusedChat() === a);

// The split leaves the new pane focused, so a command acts on the pane the user just made.
const b = new Chat();
root.split("row", b.view);
check("split-focuses-new", root.active === b.view && focusedChat() === b);
check("view-leads-back", chatOf(b.view) === b && chatOf(a.view) === a);

// Each pane holds its own session, so one pane cannot move the other.
a.connKey = "local"; a.sessionId = "s1";
b.connKey = "local"; b.sessionId = "s2";
a.transcript.setOutline([{ id: "u1", type: "user" }], null);
b.transcript.setOutline([{ id: "u2", type: "user" }, { id: "a2", type: "assistant" }], null);
check("separate-transcripts", a.transcript.messages().length === 1 && b.transcript.messages().length === 2);

// A "gone" event reaches only the pane that names the pair.
events.emit("session.changed", { type: "session", session: "s1", kind: "gone" });
check("gone-hits-one-pane", a.sessionId === null && b.sessionId === "s2");

// Two panes on one session both follow it, which a single-chat shell could never do.
a.sessionId = "s2";
let seen = 0;
const ra = a.transcript.setActive.bind(a.transcript);
const rb = b.transcript.setActive.bind(b.transcript);
a.transcript.setActive = (id) => { seen++; return ra(id); };
b.transcript.setActive = (id) => { seen++; return rb(id); };
events.emit("session.changed", { type: "session", session: "s2", kind: "active", id: 3 });
check("both-panes-follow", seen === 2);
a.transcript.setActive = ra;
b.transcript.setActive = rb;

// A closed pane releases its chat, so the registry does not keep a pane the tree dropped.
const had = chats.size;
root.focusView(b.view);
root.close();
check("close-drops-the-chat", chats.size === had - 1 && !chats.has(b));
check("close-leaves-the-other", chats.has(a) && focusedChat() === a);

// A replaced tree drops its panes, so a whole-tree swap releases them like a close.
const c1 = new Chat();
const c2 = new Chat();
c1.connKey = "local"; c1.sessionId = "s9";
root.setRoot(Node.leaf(c1.view));
check("setRoot-drops-the-pane-it-replaced", !chats.has(a));
const held = chats.size;
root.setRoot(Node.leaf(c2.view));
check("setRoot-drops-the-old-pane", chats.size === held - 1 && !chats.has(c1));
check("setRoot-keeps-the-new-pane", chats.has(c2));

// A pane that survives the swap must not be released, so only the dropped views go.
const stay = new Chat();
const drop = new Chat();
root.setRoot(Node.branch("row", Node.leaf(stay.view), Node.leaf(drop.view), 0.5));
root.setRoot(Node.leaf(stay.view));
check("setRoot-releases-only-the-dropped", chats.has(stay) && !chats.has(drop));

// A split with no active leaf must not leave its new chat in the registry.
root.setRoot(null);
const orphans = chats.size;
const tried = new Chat();
if (!root.split("row", tried.view)) tried.dispose();
check("failed-split-keeps-no-orphan", chats.size === orphans);

// A bare view is a pane for a layer, but it owns no session, so a command finds none.
const bare = { name: "chat", rect: { x: 0, y: 0, w: 1, h: 1 }, layout() {}, draw() {} };
root.setRoot(Node.leaf(bare));
check("bare-view-is-a-pane", focusedChatView() === bare);
check("bare-view-owns-no-session", focusedChat() === null);

plugins.dispose("chat");
