import { equal } from "yuke:internal/test";
import { plugins } from "yuke:internal/ext";
import { interaction } from "yuke:internal/interaction";
// Each answerer records the questions it receives, so the test sees which install answers.
const answerer = (tag) => ({ interactive: true, open: (request, _ctx, _options, resolve) => { globalThis.heard.push(tag + ":" + request.title); resolve(true); return () => {}; } });
globalThis.heard = [];
const first = interaction.install(answerer("first"));
plugins.use({ name: "asker", apply(ctx) { globalThis.ask = (m) => ctx.interaction.confirm(m); } });
globalThis.ask("a");
const second = interaction.install(answerer("second"));
globalThis.ask("b");
second();
globalThis.ask("c");
first();
equal(globalThis.heard.join(","), "first:a,second:b,first:c");

// An older disposal cannot restore a provider after its own disposal.
const base = interaction.install(answerer("base"));
const older = interaction.install(answerer("older"));
const newer = interaction.install(answerer("newer"));
older();
globalThis.ask("d");
newer();
globalThis.ask("e");
older(); newer();
globalThis.ask("f");
equal(globalThis.heard.slice(-3).join(","), "newer:d,base:e,base:f");

// Each install has its own identity, even when the provider object is the same.
const shared = answerer("shared");
const one = interaction.install(shared);
const two = interaction.install(shared);
one();
globalThis.ask("g");
two();
globalThis.ask("h");
equal(globalThis.heard.slice(-2).join(","), "shared:g,base:h");
base();
let unavailable = false;
await globalThis.ask("i").catch((e) => { unavailable = e.name === "InteractionUnavailable"; });
equal(unavailable, true);
