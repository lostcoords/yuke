import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { command, root, Node } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { plugins } from "yuke:internal/ext";
import { chatPlugin } from "yuke:internal/chat";
import { currentEntry, Session, sessionsPlugin } from "yuke:internal/session";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
// The pane must sit in the tree, because a session command acts on the focused chat.
const chat = new ChatView(new Session());
root.setRoot(Node.leaf(chat));
root.focusView(chat);

check("commands-absent-before", !command.available("model:pick"));
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
check("commands-registered", command.available("model:pick"));

// A "gone" event for the open pair closes the session; one for another pair does not.
chat.session.sessionId = "s1";
events.emit("session.changed", { type: "session", session: "other", kind: "gone" });
check("ignores-other-pair", chat.session.sessionId === "s1");
events.emit("session.changed", { type: "session", session: "s1", kind: "gone" });
check("closes-open-pair", chat.session.sessionId === null);

// The "active" and reload branches move the transcript, not just the session id.
chat.session.sessionId = "s1";
let actives = [];
const realActive = chat.transcript.setActive.bind(chat.transcript);
chat.transcript.setActive = (id) => { actives.push(id); return realActive(id); };
events.emit("session.changed", { type: "session", session: "s1", kind: "active", id: 7 });
check("active-moves-transcript", actives.join(",") === "7");
events.emit("session.changed", { type: "session", session: "s1", kind: "delta" });
check("other-kinds-reload", actives.join(",") === "7");

// A quiet digest moves nothing the transcript draws, so neither branch runs.
let reloads = 0;
const realReload = chat.session.reload.bind(chat.session);
chat.session.reload = () => { reloads++; return realReload(); };
events.emit("session.changed", { type: "session", session: "s1", kind: "reload" });
check("reload-kind-reloads", reloads === 1);
events.emit("session.changed", { type: "session", session: "s1", kind: "quiet" });
check("quiet-draws-nothing", reloads === 1 && actives.join(",") === "7");
chat.session.reload = realReload;
chat.transcript.setActive = realActive;

chat.session.sessionId = null;

// With no session the entry lookup answers null rather than reaching into a feed.
check("no-entry-without-session", currentEntry() === null);

// Each unload takes its own commands and listeners with it: the chat owns the pane commands, the session layer the rest.
plugins.dispose("chat");
check("chat-unload-drops-commands", !command.available("chat:new") && command.available("model:pick"));
plugins.dispose("sessions");
check("unload-drops-commands", !command.available("model:pick"));
chat.session.sessionId = "s2";
events.emit("session.changed", { type: "session", session: "s2", kind: "gone" });
check("unload-stops-listening", chat.session.sessionId === "s2");
chat.session.sessionId = null;
