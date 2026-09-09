import { equal } from "yuke:test";
import { events } from "yuke:kernel";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };
const view = ["ui.start", "key.press", "mouse.input", "session.changed", "index.changed"];
const accepted = view.filter((n) => !throws(() => events.on(n, () => {})));
// The neutral name stays, and an owner:event name stays free.
const neutral = !throws(() => events.on("ext.error", () => {}));
const owned = !throws(() => events.on("myplugin:ready", () => {}));
equal(accepted.length === 0 && neutral && owned ? "ok" : "accepted:" + accepted.join("|"), "ok");
