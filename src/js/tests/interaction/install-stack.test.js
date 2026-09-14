import { equal } from "yuke:test";
import { interaction, plugins } from "yuke:ext";
const answerer = (tag) => ({ surfaceFor: () => ({ notify: (m) => { globalThis.heard.push(tag + ":" + m); } }) });
globalThis.heard = [];
const first = interaction.install(answerer("first"));
plugins.use({ name: "reporter", apply(ctx) { globalThis.say = (m) => ctx.interaction.notify(m); } });
globalThis.say("a");
const second = interaction.install(answerer("second"));
globalThis.say("b");
second();
globalThis.say("c");
first();
equal(globalThis.heard.join(","), "first:a,second:b,first:c");

// An older disposal cannot restore a provider after its own disposal.
const base = interaction.install(answerer("base"));
const older = interaction.install(answerer("older"));
const newer = interaction.install(answerer("newer"));
older();
globalThis.say("d");
newer();
globalThis.say("e");
older(); newer();
globalThis.say("f");
equal(globalThis.heard.slice(-3).join(","), "newer:d,base:e,base:f");

// Each install has its own identity, even when the provider object is the same.
const shared = answerer("shared");
const one = interaction.install(shared);
const two = interaction.install(shared);
one();
globalThis.say("g");
two();
globalThis.say("h");
equal(globalThis.heard.slice(-2).join(","), "shared:g,base:h");
base();
let unavailable = false;
try { globalThis.say("i"); } catch (e) { unavailable = e.name === "InteractionUnavailable"; }
equal(unavailable, true);
