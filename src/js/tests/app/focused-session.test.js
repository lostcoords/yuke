import { check, equal } from "yuke:test";
import { client } from "yuke";
import { Context, Scope } from "yuke:ext";
import { Chat, focusedChat, focusedSessionId } from "yuke/chat";
import { focusedSessionId as internalQuery } from "yuke:chat";
import { root, Node } from "yuke:core";

equal(focusedSessionId, internalQuery);
client.sessionOpen = id => id !== "missing";
client.sessionClose = () => {};
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [], active: null });
client.sessionCheckContext = async () => ({});

const observer = new Context(new Scope("focus-test"), "focus-test");
const seen = [];
observer.on("session.focused", (...args) => {
  equal(args.length, 0);
  seen.push(focusedSessionId());
});
const a = new Chat(), b = new Chat();
equal(focusedSessionId(), null);
a.open("a");
b.open("b");
equal(seen.length, 0);
root.setRoot(Node.leaf(a.view));
equal(focusedSessionId(), "a");
root.split("h", b.view);
equal(focusedSessionId(), "b");
b.open("c");
b.open("c");
b.open("missing");
equal(seen.join(","), "a,b,c");
a.open("background");
equal(seen.length, 3);

const overlay = { layout() {}, draw() {} };
root.pushOverlay(overlay);
equal(focusedSessionId(), "c");
root.popOverlay(overlay);
equal(seen.length, 3);

const other = { name: "other", layout() {}, draw() {} };
root.split("v", other);
equal(focusedSessionId(), null);
check("commands retain their fallback", focusedChat() !== null);
root.close();
equal(focusedSessionId(), "c");
b.newChat();
equal(focusedSessionId(), null);
b.open("gone");
b.sessionGone();
equal(focusedSessionId(), null);
b.open("background");
const beforeClose = seen.length;
root.close();
equal(focusedSessionId(), "background");
equal(seen.length, beforeClose);
b.dispose();
equal(seen.length, beforeClose);

// A listener can replace the session after the first open has completed.
const stop = observer.on("session.focused", () => {
  if (focusedSessionId() === "replace") a.open("replacement");
});
a.open("replace");
equal(focusedSessionId(), "replacement");
equal(seen.slice(-2).join(","), "replace,replacement");
stop();
root.setRoot(null);
equal(focusedSessionId(), null);
const beforeDispose = seen.length;
observer.scope.dispose();
root.setRoot(Node.leaf(a.view));
equal(focusedSessionId(), "replacement");
equal(seen.length, beforeDispose);
a.dispose();
equal(focusedSessionId(), null);
root.setRoot(null);
