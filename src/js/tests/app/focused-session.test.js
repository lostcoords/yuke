import { check, equal } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { client } from "yuke";
import { Context, Scope, scopeOf } from "yuke:internal/ext";
import { currentChat } from "yuke:chat";
import { currentChat as internalQuery, Session, openSession, showSession } from "yuke:internal/chat";
import { root, Node } from "yuke:internal/core";

equal(currentChat, internalQuery);
const currentSessionId = () => currentChat()?.session.sessionId ?? null;
client.sessionOpen = id => id !== "missing";
client.sessionClose = () => {};
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [], active: null });
client.sessionCheckContext = async () => ({});

const observer = new Context(new Scope("focus-test"), "focus-test");
const seen = [];
observer.on("chat.current.changed", (...args) => {
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
check("a non-chat pane keeps the current chat", currentChat() === b);
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
b.session.leave(b);
equal(seen.length, beforeClose);

// A listener can replace the session after the first open has completed.
const stop = observer.on("chat.current.changed", () => {
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
root.setRoot(Node.leaf(a));
equal(currentSessionId(), "replacement");
equal(seen.length, beforeDispose);
a.session.leave(a);
equal(currentSessionId(), null);
root.setRoot(null);
