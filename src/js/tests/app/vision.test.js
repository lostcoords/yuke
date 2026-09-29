import { check, listSessions } from "yuke:internal/test";
import { events } from "yuke:internal/kernel";
import { catalogOf } from "yuke:internal/catalog";
import { client } from "yuke:internal/client";
import { currentPane } from "yuke:internal/session";
import { Composer } from "yuke:internal/ui";
// The messages posted since the last reset, as the user saw them. A repeat posts again, so it counts too.
const shown = [];
events.on("notify.posted", (n) => shown.push(n.message));
const lastShown = () => shown[shown.length - 1] ?? "";

// The shell built the first chat pane at boot.
const chat = currentPane();
const png = { hash: "a".repeat(64), mime: "image/png", bytes: 2048 };
const blind = { id: "m1", provider: "p", selector: "p/blind", name: "Blind", reasoning_levels: [], default_reasoning: "", supports_vision: false, cost: {} };
const seeing = { id: "m2", provider: "p", selector: "p/seeing", name: "Seeing", reasoning_levels: [], default_reasoning: "", supports_vision: true, cost: {} };
const quiet = { id: "m3", provider: "p", selector: "p/quiet", name: "Quiet", reasoning_levels: [], default_reasoning: "", cost: {} };
catalogOf().models = [blind, seeing, quiet];

const attach = () => { chat.composer.spans = [{ start: 0, end: 6, blob: png }]; };
const clear = () => { chat.composer.spans = []; chat.composer.text = ""; shown.length = 0; };

// With no attachment the model choice says nothing about images.
clear();
chat.session.setModel(blind, "");
check("no-images-no-warning", lastShown().indexOf("reads no images") < 0);

// An attachment under a model that reads none warns, and it names the model.
clear();
chat.composer.text = "/a.png";
attach();
events.emit("composer.attached", chat.composer);
check("attach-warns", lastShown() === "Blind reads no images");

// An attachment in another pane says nothing about the images this pane holds.
shown.length = 0;
events.emit("composer.attached", new Composer({}));
check("other-attach-is-quiet", lastShown() === "");

// The same composer under a model that reads images says nothing.
shown.length = 0;
chat.session.setModel(seeing, "");
check("seeing-is-quiet", lastShown().indexOf("reads no images") < 0);

// A catalog entry that says nothing about vision never raises a warning.
shown.length = 0;
chat.session.setModel(quiet, "");
check("unknown-is-quiet", lastShown().indexOf("reads no images") < 0);

// Moving back to a model that reads none warns again, because the attachment is still there.
shown.length = 0;
chat.session.setModel(blind, "");
check("switch-warns", lastShown() === "Blind reads no images");

// Remove the attachment and the same switch says nothing.
chat.composer.spans = [];
shown.length = 0;
chat.session.setModel(seeing, "");
chat.session.setModel(blind, "");
check("removed-images-are-quiet", lastShown().indexOf("reads no images") < 0);

// An open session checks the model the patch sets, because the feed still names the old model.
client.sessionPatch = async () => ({});
await listSessions([{ session: { id: "s1", model: "p/seeing" }, activity: null }]);
chat.session.sessionId = "s1";
chat.composer.text = "/a.png";
attach();
shown.length = 0;
chat.session.setModel(blind, "");
// An open session takes the model when the engine accepts the patch, so the warning follows the answer.
for (let i = 0; i < 4; i++) await Promise.resolve();
check("open-session-warns", lastShown() === "Blind reads no images");
chat.session.sessionId = null;
await listSessions([]);
clear();
