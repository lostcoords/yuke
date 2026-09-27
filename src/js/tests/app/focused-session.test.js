import { check, equal } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { client } from "yuke";
import { Context, Scope, scopeOf } from "yuke:internal/ext";
import { currentPane } from "yuke:session";
import { chatPlugin } from "yuke:internal/chat";
import { currentPane as internalQuery, Session, openSession, showSession, sessionsPlugin } from "yuke:internal/session";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { root, Node } from "yuke:internal/core";

equal(currentPane, internalQuery);
// The chat plugin tracks the current chat while the terminal exists.
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
const currentSessionId = () => currentPane()?.session.sessionId ?? null;
client.sessionOpen = id => id !== "missing";
client.sessionClose = () => {};
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [], active: null });
client.sessionCheckContext = async () => ({});

const observer = new Context(new Scope("focus-test"), "focus-test");
const seen = [];
observer.on("session.current.changed", (...args) => {
  equal(args.length, 0);
  seen.push(currentSessionId());
});
const a = new ChatView(new Session()), b = new ChatView(new Session());
equal(currentSessionId(), null);
openSession(a, "a");
openSession(b, "b");
equal(seen.length, 0);
root.setRoot(Node.leaf(a));
equal(currentSessionId(), "a");
root.split("h", b);
equal(currentSessionId(), "b");
openSession(b, "c");
openSession(b, "c");
openSession(b, "missing");
equal(seen.join(","), "a,b,c");
openSession(a, "background");
equal(seen.length, 3);

const overlay = { layout() {}, draw() {} };
root.pushOverlay(overlay);
equal(currentSessionId(), "c");
root.popOverlay(overlay);
equal(seen.length, 3);

// A focused pane that is not a chat leaves the current chat in place and announces nothing.
const other = { name: "other", layout() {}, draw() {} };
root.split("v", other);
equal(root.active, other);
check("a non-chat pane keeps the current chat", currentPane() === b);
equal(seen.length, 3);
root.close();
equal(currentSessionId(), "c");
equal(seen.length, 3);
showSession(b, new Session());
equal(currentSessionId(), null);
openSession(b, "gone");
b.session.sessionGone();
equal(currentSessionId(), null);
openSession(b, "background");
const beforeClose = seen.length;
root.close();
equal(currentSessionId(), "background");
equal(seen.length, beforeClose);

// A listener can replace the session after the first open has completed.
const stop = observer.on("session.current.changed", () => {
  if (currentSessionId() === "replace") openSession(a, "replacement");
});
openSession(a, "replace");
equal(currentSessionId(), "replacement");
equal(seen.slice(-2).join(","), "replace,replacement");
stop();
root.setRoot(null);
equal(currentSessionId(), null);
const beforeDispose = seen.length;
scopeOf(observer).dispose();
// The closed pane left its session, so a new pane opens it again.
const c = new ChatView(new Session());
openSession(c, "replacement");
root.setRoot(Node.leaf(c));
equal(currentSessionId(), "replacement");
equal(seen.length, beforeDispose);
// The close leaves the session, and the last view drops its id.
root.setRoot(null);
equal(currentSessionId(), null);
