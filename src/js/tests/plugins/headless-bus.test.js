import { equal } from "yuke:internal/test";
import { events } from "yuke:internal/kernel";
import "yuke:internal/client";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };
const view = ["ui.started", "key.pressed", "mouse.received"];
const accepted = view.filter((n) => !throws(() => events.on(n, () => {})));
// The neutral name stays, and an owner:event name stays free.
const neutral = !throws(() => events.on("ext.failed", () => {}));
const owned = !throws(() => events.on("myplugin:ready", () => {}));
// A drain never carries a job change, so the bus refuses a name that could never fire.
const undelivered = throws(() => events.on("job.changed", () => {}));
equal(accepted.length === 0 && neutral && owned && undelivered ? "ok" : "accepted:" + accepted.join("|"), "ok");

// The client runs in every frontend, so a drain reaches a headless listener as `session.changed` and faults nothing.
{
  const failed = [];
  const offFail = events.on("ext.failed", (error) => failed.push(String(error)));
  let seen = null;
  const offSeen = events.on("session.changed", (ev) => { seen = ev.session; });
  events.emit("engine.drained", { type: "session", session: "s1", kind: "quiet", facts: [] });
  offFail();
  offSeen();
  equal(failed.length === 0 && seen === "s1" ? "ok" : "failed:" + failed.join("|"), "ok");
}
