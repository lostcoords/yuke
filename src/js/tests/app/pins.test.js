import { check } from "yuke:internal/test";
import { ChatView } from "yuke:internal/chat-view";
import { Session, showSession } from "yuke:internal/session";
import { client } from "yuke:internal/client";
import { events } from "yuke:internal/kernel";
// The messages posted since the last reset, as the user saw them. A repeat posts again, so it counts too.
const shown = [];
events.on("notify.posted", (n) => shown.push(n.message));
const lastShown = () => shown[shown.length - 1] ?? "";

const opened = [], closed = [];
client.sessionOpen = id => { opened.push(id); return id !== "missing"; };
client.sessionClose = id => { closed.push(id); };
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [{ id: 1, type: "user" }], active: null });
const chat = new ChatView(new Session());
showSession(chat, "missing");
check("failed-first-open", chat.session.sessionId === null && closed.length === 0 && lastShown().includes("open failed"));
showSession(chat, "old");
showSession(chat, "missing");
check("failed-replacement-keeps-pin", chat.session.sessionId === "old" && closed.length === 0 && chat.transcript.messages().length === 1);
showSession(chat, "next");
check("replacement-releases-once", chat.session.sessionId === "next" && closed.join(",") === "old");
showSession(chat, "next");
check("same-session-reuses-pin", opened.join(",") === "missing,old,missing,next");
chat.session.leave(chat);
check("dispose-releases-owned-pin", closed.join(",") === "old,next");
