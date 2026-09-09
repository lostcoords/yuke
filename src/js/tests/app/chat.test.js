import { check } from "yuke:test";
import { command, events, root, Node } from "yuke:core";
import { plugins } from "yuke:ext";
import { Chat, chatEntry, chatPlugin } from "yuke:chat";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
// The pane must sit in the tree, because a session command acts on the focused chat.
const chat = new Chat();
root.setRoot(Node.leaf(chat.view));
root.focusView(chat.view);

check("commands-absent-before", !command.available("model:pick"));
plugins.use(chatPlugin);
check("commands-registered", command.available("model:pick"));

// A "gone" event for the open pair closes the session; one for another pair does not.
chat.sessionId = "s1";
events.emit("session.changed", { type: "session", session: "other", kind: "gone" });
check("ignores-other-pair", chat.sessionId === "s1");
events.emit("session.changed", { type: "session", session: "s1", kind: "gone" });
check("closes-open-pair", chat.sessionId === null);

// The "active" and reload branches move the transcript, not just the session id.
chat.sessionId = "s1";
let actives = [];
const realActive = chat.transcript.setActive.bind(chat.transcript);
chat.transcript.setActive = (id) => { actives.push(id); return realActive(id); };
events.emit("session.changed", { type: "session", session: "s1", kind: "active", id: 7 });
check("active-moves-transcript", actives.join(",") === "7");
events.emit("session.changed", { type: "session", session: "s1", kind: "delta" });
check("other-kinds-reload", actives.join(",") === "7");

// A quiet digest moves nothing the transcript draws, so neither branch runs.
let reloads = 0;
const realReload = chat.reload.bind(chat);
chat.reload = () => { reloads++; return realReload(); };
events.emit("session.changed", { type: "session", session: "s1", kind: "reload" });
check("reload-kind-reloads", reloads === 1);
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet" });
check("quiet-draws-nothing", reloads === 1 && actives.join(",") === "7");
chat.reload = realReload;
chat.transcript.setActive = realActive;

chat.sessionId = null;

// With no session the entry lookup answers null rather than reaching into a feed.
check("no-entry-without-session", chatEntry() === null);

// An unload takes the commands and the listeners with it.
plugins.dispose("chat");
check("unload-drops-commands", !command.available("model:pick"));
chat.sessionId = "s2";
events.emit("session.changed", { type: "session", session: "s2", kind: "gone" });
check("unload-stops-listening", chat.sessionId === "s2");
chat.sessionId = null;
