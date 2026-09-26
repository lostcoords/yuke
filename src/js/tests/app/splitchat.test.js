import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { root, Node } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { plugins } from "yuke:internal/ext";
import { chatPlugin } from "yuke:internal/chat";
import { sessions, currentPane, openSession, showSession, Session, sessionsPlugin } from "yuke:internal/session";
import { tuiPlugin } from "yuke:internal/tui";
import { client } from "yuke:internal/client";
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);

const a = new ChatView(new Session());
root.setRoot(Node.leaf(a));
root.focusView(a);
check("first-is-focused", currentPane() === a);

// The split leaves the new pane focused, so a command acts on the pane the user just made.
const b = new ChatView(new Session());
root.split("row", b);
check("split-focuses-new", root.active === b && currentPane() === b);
check("each-pane-has-its-own-session", a.session !== b.session && sessions.has(a.session) && sessions.has(b.session));

// Each pane holds its own session, so one pane cannot move the other.
a.session.sessionId = "s1";
b.session.sessionId = "s2";
a.transcript.setOutline([{ id: "u1", type: "user" }], null);
b.transcript.setOutline([{ id: "u2", type: "user" }, { id: "a2", type: "assistant" }], null);
check("separate-transcripts", a.transcript.messages().length === 1 && b.transcript.messages().length === 2);

// A "gone" event reaches only the pane that names the pair.
events.emit("session.changed", { type: "session", session: "s1", kind: "gone" });
check("gone-hits-one-pane", a.session.sessionId === null && b.session.sessionId === "s2");

// Two panes on one session share it: one session, one pin, and an event updates both views.
showSession(a, b.session);
check("panes-share-a-session", a.session === b.session && b.session.views.length === 2);
let seen = 0;
const ra = a.transcript.setActive.bind(a.transcript);
const rb = b.transcript.setActive.bind(b.transcript);
a.transcript.setActive = (id) => { seen++; return ra(id); };
b.transcript.setActive = (id) => { seen++; return rb(id); };
events.emit("session.changed", { type: "session", session: "s2", kind: "active", id: 3 });
check("both-panes-follow", seen === 2);
a.transcript.setActive = ra;
b.transcript.setActive = rb;

// A closed pane leaves the shared session, and the session stays while another view shows it.
const shared = a.session;
root.focusView(b);
root.close();
check("close-keeps-a-shown-session", sessions.has(shared) && shared.views.length === 1 && shared.views.includes(a));
check("close-leaves-the-other", currentPane() === a);

// An open of a session another view shows shares it, so the engine pins it once; the view already there keeps its selection.
a.transcript.selection = { anchor: { id: "u2", row: 0, col: 0 }, cursor: { id: "u2", row: 0, col: 1 } };
const outline = client.sessionOutline;
client.sessionOutline = () => ({ messages: [{ id: "u2", type: "user" }], active: null });
const joiner = new ChatView(new Session());
openSession(joiner, "s2");
client.sessionOutline = outline;
check("open-shares-a-shown-session", joiner.session === shared && shared.views.length === 2);
check("join-keeps-the-other-selection", a.transcript.selection !== null);
shared.leave(joiner);

// A replaced tree drops its panes, so a whole-tree swap releases them like a close.
const c1 = new ChatView(new Session());
const c2 = new ChatView(new Session());
c1.session.sessionId = "s9";
root.setRoot(Node.leaf(c1));
check("setRoot-drops-the-pane-it-replaced", !sessions.has(shared));
const held = sessions.size;
root.setRoot(Node.leaf(c2));
check("setRoot-drops-the-old-pane", sessions.size === held - 1 && !sessions.has(c1.session));
check("setRoot-keeps-the-new-pane", sessions.has(c2.session));

// A pane that survives the swap must not be released, so only the dropped views go.
const stay = new ChatView(new Session());
const drop = new ChatView(new Session());
root.setRoot(Node.branch("row", Node.leaf(stay), Node.leaf(drop), 0.5));
root.setRoot(Node.leaf(stay));
check("setRoot-releases-only-the-dropped", sessions.has(stay.session) && !sessions.has(drop.session));

// A split with no active leaf must not leave its new chat in the registry.
root.setRoot(null);
const orphans = sessions.size;
const tried = new ChatView(new Session());
if (!root.split("row", tried)) tried.session.leave(tried);
check("failed-split-keeps-no-orphan", sessions.size === orphans);

// A focused pane that is not a chat leaves the current chat in place, as a sidebar leaves the previous window.
const keep = new ChatView(new Session());
const bare = { name: "chat", rect: { x: 0, y: 0, w: 1, h: 1 }, layout() {}, draw() {} };
root.setRoot(Node.branch("row", Node.leaf(keep), Node.leaf(bare), 0.5));
root.focusView(bare);
check("non-chat-pane-keeps-current", root.active === bare && currentPane() === keep);
// A closed current chat hands over to a chat left in the tree, and to none when no chat is left.
root.focusView(keep);
root.close();
check("closed-current-hands-over", root.active === bare && currentPane() === null);
root.setRoot(null);

plugins.dispose("chat");
