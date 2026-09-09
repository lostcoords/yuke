import { equal } from "yuke:test";
import { root } from "yuke:core";
const log = [];
const b = { onStart() { log.push("b-start"); }, onStop() { log.push("b-stop"); } };
const a = { onStart() { log.push("a-start"); root.removeTickable(b); } };
root.addTickable(a);
root.addTickable(b);
root.onEvent({ type: "start" });
equal(log.join(",") + "|" + (root.hasTickable(b) ? "held" : "gone"), "a-start|gone");
