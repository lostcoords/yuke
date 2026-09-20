import { check } from "yuke:test";
import { command, keymap } from "yuke:core";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
// The stub stands for the native counts, so the guard reads one load shape in the test and in the app.
let load = { runs: 0, childRuns: 0, continuations: 0 };
client.load = () => load;
globalThis.setLoad = (next) => { load = next; };
globalThis.quitAgain = () => command.perform("quit");
globalThis.shown = () => notice.text;
// The clock is a stub, so the window and a clock step back are exact.
let now = 100000;
Date.now = () => now;
globalThis.tick = (ms) => { now += ms; };
// A busy engine holds the first ask and shows the hint.
setLoad({ runs: 3, childRuns: 2, continuations: 0 });
quitAgain();
check("first-ask-holds", shown() === "2 agents working · ctrl+q again to stop it and quit");
// The hint names the stroke that runs quit here, so a remap changes the words and an unbound quit names the slash word.
const offTaken = keymap.add({ "ctrl+q": "ui:palette" });
tick(4000); setLoad({ runs: 1, childRuns: 0, continuations: 0 }); quitAgain();
check("hint-unbound", shown() === "a run in progress · /quit again to stop it and quit");
const offRemap = keymap.add({ "ctrl+x": "quit" });
tick(4000); setLoad({ runs: 2, childRuns: 1, continuations: 0 }); quitAgain();
check("hint-remap", shown() === "1 agent working · ctrl+x again to stop it and quit");
offRemap(); offTaken();
tick(4000); setLoad({ runs: 0, childRuns: 0, continuations: 1 }); quitAgain();
check("hint-continuation", shown() === "a run in progress · ctrl+q again to stop it and quit");
