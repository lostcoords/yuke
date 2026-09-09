import { check } from "yuke:test";
import { status, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { notice, noticePlugin } from "yuke:notice";
import { catalogPlugin, catalogOf, chooseModel, tokenLabel, contextWindowOf } from "yuke:catalog";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);

let open = null;
plugins.use(catalogPlugin, { entry: () => open });

// With no session the reading falls back to the default model.
check("empty-without-session", status.side("right") === "");
// A choice tells the user and asks for a repaint, or the new model never reaches the screen.
plugins.use(noticePlugin);
root._needsDraw = false;
chooseModel({ selector: "m-1", name: "m-1" }, "high");
check("choice-notifies", notice.text === "model · m-1 · high");
check("choice-repaints", root._needsDraw === true);
check("default-model-shows", status.side("right").indexOf("m-1") >= 0);

// An open session names its own model instead of the default.
open = { session: { id: "s", model: "session-model" }, activity: null };
check("session-model-wins", status.side("right").indexOf("session-model") >= 0);

// The window of a model the catalog names, and zero for the rest.
catalogOf().models = [{ selector: "session-model", context_window: 10000 }];
check("known-window", contextWindowOf("session-model") === 10000 && contextWindowOf("other") === 0);
catalogOf().models = [];
check("token-label", tokenLabel(999) === "999" && tokenLabel(2500) === "2.5k" && tokenLabel(20000) === "20k");

// An unload takes the reading away.
plugins.dispose("catalog");
check("unload-drops-reading", status.side("right") === "");
