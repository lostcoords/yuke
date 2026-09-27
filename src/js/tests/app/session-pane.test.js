import { check } from "yuke:internal/test";
import { root, Node } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { plugins } from "yuke:internal/ext";
import { client } from "yuke:internal/client";
import { tuiPlugin } from "yuke:internal/tui";
import { Transcript } from "yuke:internal/transcript";
import { Session, sessions, currentPane, currentSession, openSession, sessionsPlugin } from "yuke:internal/session";

const closed = [];
client.sessionOpen = () => true;
client.sessionClose = (id) => { closed.push(id); };
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [], active: null });
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);

// A pane that is no chat pane: a transcript alone. It holds a session, so the session layer serves it.
// A session that no view shows is not listed, so no event or frame walks it.
check("unshown-session-unlisted", !sessions.includes(new Session()));
const session = new Session();
const pane = { name: "reader", rect: { x: 0, y: 0, w: 0, h: 0 }, session, transcript: new Transcript({}), layout() {}, draw() {} };
session.join(pane);
root.setRoot(Node.leaf(pane));
check("focus-makes-current", currentPane() === pane && currentSession() === session);

openSession(pane, "s1");
let actives = 0;
pane.transcript.setActive = () => { actives++; };
events.emit("session.changed", { type: "session", session: "s1", kind: "active", id: 3, facts: [] });
check("stream-reaches-pane", actives === 1);

// The close takes the pane out of the tree, so the session loses its last view and releases the pin.
root.setRoot(null);
check("close-releases-pin", closed.join(",") === "s1" && currentPane() === null && !sessions.includes(pane.session));
