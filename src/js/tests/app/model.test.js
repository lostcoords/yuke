import { check, listSessions } from "yuke:internal/test";
import { status, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { catalogOf, contextWindowOf } from "yuke:internal/catalog";
import { tokenLabel } from "yuke:internal/format";
import { chatPlugin } from "yuke:internal/chat";
import { client } from "yuke:internal/client";
import { currentPane, defaultModel, sessionsPlugin } from "yuke:internal/session";
import { shell } from "yuke:internal/shell";
import { tuiPlugin } from "yuke:internal/tui";
import { events } from "yuke:internal/kernel";
// The messages posted since the last reset, as the user saw them. A repeat posts again, so it counts too.
const shown = [];
events.on("notify.posted", (n) => shown.push(n.message));
const lastShown = () => shown[shown.length - 1] ?? "";

plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
plugins.use(shell);
const chat = currentPane();

// With no session and no choice the status shows no model.
check("empty-without-session", status.side("right") === "");
// A choice tells the user and asks for a repaint, or the new model never reaches the screen.
root._needsDraw = false;
chat.session.setModel({ selector: "m-1", name: "m-1" }, "high");
check("choice-notifies", lastShown() === "m-1 · high");
check("choice-repaints", root._needsDraw === true);
check("default-model-shows", status.side("right").indexOf("m-1") >= 0);

// An open session names its own model instead of the default.
await listSessions([{ session: { id: "s", model: "session-model" }, activity: null }]);
chat.session.sessionId = "s";
check("session-model-wins", status.side("right").indexOf("session-model") >= 0);

// A refused patch never changes the default, so it cannot undo a later choice the engine accepted.
/** @type {(error: Error) => void} */
let refuse = () => {};
client.sessionPatch = (_id, patch) => patch.model === "m-a" ? new Promise((_, reject) => { refuse = reject; }) : Promise.resolve({});
chat.session.setModel({ selector: "m-a", name: "m-a" }, "");
chat.session.setModel({ selector: "m-b", name: "m-b" }, "");
for (let i = 0; i < 4; i++) await Promise.resolve();
check("accepted-choice", defaultModel().model === "m-b");
refuse(new Error("refused"));
for (let i = 0; i < 4; i++) await Promise.resolve();
check("refusal-shown", lastShown() === "refused");
check("refused-patch-keeps-later-choice", defaultModel().model === "m-b");
chat.session.sessionId = null;
await listSessions([]);

// The window of a model the catalog names, and zero for the rest.
catalogOf().models = [{ selector: "session-model", context_window: 10000 }];
check("known-window", contextWindowOf("session-model") === 10000 && contextWindowOf("other") === 0);
catalogOf().models = [];
check("token-label", tokenLabel(999) === "999" && tokenLabel(2500) === "2.5k" && tokenLabel(20000) === "20k");

// The session layer owns the reading, so its unload takes the reading away.
plugins.dispose("sessions");
check("unload-drops-reading", status.side("right") === "");
