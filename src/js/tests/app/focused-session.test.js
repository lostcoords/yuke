import { check, equal } from "yuke:internal/test";
import { client } from "yuke";
import { Context, Scope, scopeOf } from "yuke:internal/ext";
import { Chat, currentChat } from "yuke:chat";
import { currentChat as internalQuery } from "yuke:internal/chat";
import { root, Node } from "yuke:internal/core";

equal(currentChat, internalQuery);
const currentSessionId = () => currentChat()?.sessionId ?? null;
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
const a = new Chat(), b = new Chat();
equal(currentSessionId(), null);
a.open("a");
b.open("b");
equal(seen.length, 0);
root.setRoot(Node.leaf(a.view));
equal(currentSessionId(), "a");
root.split("h", b.view);
equal(currentSessionId(), "b");
b.open("c");
b.open("c");
b.open("missing");
equal(seen.join(","), "a,b,c");
a.open("background");
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
b.newChat();
equal(currentSessionId(), null);
b.open("gone");
b.sessionGone();
equal(currentSessionId(), null);
b.open("background");
const beforeClose = seen.length;
root.close();
equal(currentSessionId(), "background");
equal(seen.length, beforeClose);
b.dispose();
equal(seen.length, beforeClose);

// A listener can replace the session after the first open has completed.
const stop = observer.on("chat.current.changed", () => {
  if (currentSessionId() === "replace") a.open("replacement");
});
a.open("replace");
equal(currentSessionId(), "replacement");
equal(seen.slice(-2).join(","), "replace,replacement");
stop();
root.setRoot(null);
equal(currentSessionId(), null);
const beforeDispose = seen.length;
scopeOf(observer).dispose();
root.setRoot(Node.leaf(a.view));
equal(currentSessionId(), "replacement");
equal(seen.length, beforeDispose);
a.dispose();
equal(currentSessionId(), null);
root.setRoot(null);
