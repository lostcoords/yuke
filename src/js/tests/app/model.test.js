import { check } from "yuke:internal/test";
import { status, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { notice, noticePlugin } from "yuke:internal/notice";
import { catalogOf, contextWindowOf } from "yuke:internal/catalog";
import { tokenLabel } from "yuke:internal/format";
import { chatPlugin } from "yuke:internal/chat";
import { currentPane, feedOf, sessionsPlugin } from "yuke:internal/session";
import { shell } from "yuke:internal/shell";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
plugins.use(shell);
const chat = currentPane();

// With no session and no choice the status shows no model.
check("empty-without-session", status.side("right") === "");
// A choice tells the user and asks for a repaint, or the new model never reaches the screen.
plugins.use(noticePlugin);
root._needsDraw = false;
chat.session.setModel({ selector: "m-1", name: "m-1" }, "high");
check("choice-notifies", notice.text === "model · m-1 · high");
check("choice-repaints", root._needsDraw === true);
check("default-model-shows", status.side("right").indexOf("m-1") >= 0);

// An open session names its own model instead of the default.
feedOf().items.set("s", { session: { id: "s", model: "session-model" }, activity: null });
chat.session.sessionId = "s";
check("session-model-wins", status.side("right").indexOf("session-model") >= 0);
chat.session.sessionId = null;
feedOf().items.delete("s");

// The window of a model the catalog names, and zero for the rest.
catalogOf().models = [{ selector: "session-model", context_window: 10000 }];
check("known-window", contextWindowOf("session-model") === 10000 && contextWindowOf("other") === 0);
catalogOf().models = [];
check("token-label", tokenLabel(999) === "999" && tokenLabel(2500) === "2.5k" && tokenLabel(20000) === "20k");

// The session layer owns the reading, so its unload takes the reading away.
plugins.dispose("sessions");
check("unload-drops-reading", status.side("right") === "");
