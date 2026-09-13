import { check } from "yuke:test";
import { events } from "yuke:core";
import { notice } from "yuke:notice";
import { catalogOf, chooseModel } from "yuke:catalog";
import { chat } from "yuke:defaults";
import { client } from "yuke:client";
import { feedOf } from "yuke:sessions";
const png = { hash: "a".repeat(64), mime: "image/png", bytes: 2048 };
const blind = { id: "m1", provider: "p", selector: "p/blind", name: "Blind", reasoning_levels: [], default_reasoning: "", supports_vision: false, cost: {} };
const seeing = { id: "m2", provider: "p", selector: "p/seeing", name: "Seeing", reasoning_levels: [], default_reasoning: "", supports_vision: true, cost: {} };
const quiet = { id: "m3", provider: "p", selector: "p/quiet", name: "Quiet", reasoning_levels: [], default_reasoning: "", cost: {} };
catalogOf().models = [blind, seeing, quiet];

const attach = () => { chat.composer.spans = [{ start: 0, end: 6, blob: png }]; };
const clear = () => { chat.composer.spans = []; chat.composer.text = ""; notice.clear(); };

// With no attachment the model choice says nothing about images.
clear();
chooseModel(blind, "");
check("no-images-no-warning", notice.text.indexOf("reads no images") < 0);

// An attachment under a model that reads none warns, and it names the model.
clear();
chat.composer.text = "/a.png";
attach();
events.emit("composer.attached", chat.composer);
check("attach-warns", notice.text === "Blind reads no images");

// The same composer under a model that reads images says nothing.
notice.clear();
chooseModel(seeing, "");
check("seeing-is-quiet", notice.text.indexOf("reads no images") < 0);

// A catalog entry that says nothing about vision never raises a warning.
notice.clear();
chooseModel(quiet, "");
check("unknown-is-quiet", notice.text.indexOf("reads no images") < 0);

// Moving back to a model that reads none warns again, because the attachment is still there.
notice.clear();
chooseModel(blind, "");
check("switch-warns", notice.text === "Blind reads no images");

// Remove the attachment and the same switch says nothing.
chat.composer.spans = [];
notice.clear();
chooseModel(seeing, "");
chooseModel(blind, "");
check("removed-images-are-quiet", notice.text.indexOf("reads no images") < 0);

// An open session checks the model the patch sets, because the feed still names the old model.
client.sessionPatch = async () => ({});
feedOf().items.set("s1", { session: { id: "s1", model: "p/seeing" }, activity: null });
chat.sessionId = "s1";
chat.composer.text = "/a.png";
attach();
notice.clear();
chooseModel(blind, "", "s1");
check("open-session-warns", notice.text === "Blind reads no images");
chat.sessionId = null;
feedOf().items.delete("s1");
clear();
