import { check } from "yuke:test";
import { root } from "yuke:core";
import { plugins } from "yuke:ext";
import { tui } from "yuke:tui";
// A service starts and stops only after the shell starts, the way `onStart` already worked.
root.onEvent({ type: "start" });

const log = [];
const svc = { onStart() { log.push("start"); }, onStop() { log.push("stop"); } };
const before = root.tickables.length;
plugins.use({ name: "svc-test", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(svc); } });
check("added", root.hasTickable(svc) && root.tickables.length === before + 1);
check("started", log.join(",") === "start");
plugins.dispose("svc-test");
check("removed", !root.hasTickable(svc) && root.tickables.length === before);
check("stopped", log.join(",") === "start,stop");

// Two owners share one entry, so one unload cannot stop what the other still holds.
log.length = 0;
plugins.use({ name: "own-a", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(svc); } });
plugins.use({ name: "own-b", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(svc); } });
check("shared-starts-once", log.join(",") === "start");
plugins.dispose("own-a");
check("shared-holds", root.hasTickable(svc) && log.join(",") === "start");
plugins.dispose("own-b");
check("shared-stops-last", !root.hasTickable(svc) && log.join(",") === "start,stop");

// A throwing `onStart` registers nothing, so a failed scope leaves no service behind.
const bad = { onStart() { throw new Error("bad start"); } };
let threw = 0;
try { plugins.use({ name: "bad", apply(ctx) { const t = tui.bindTo(ctx); t.tickable(bad); } }); } catch (e) { threw = 1; }
check("bad-start-rejected", threw === 1 && !root.hasTickable(bad) && !plugins.get("bad"));

// A throwing `onStop` still restores the tick state.
let synced = 0;
const realSync = root.syncTick.bind(root);
root.syncTick = () => { synced++; return realSync(); };
const noisy = { needsTick() { return { periodMs: 5 }; }, onStop() { throw new Error("bad stop"); } };
root.addTickable(noisy);
const s0 = synced;
let stopThrew = 0;
try { root.removeTickable(noisy); } catch (e) { stopThrew = 1; }
check("bad-stop-syncs", stopThrew === 1 && !root.hasTickable(noisy) && synced > s0);
root.syncTick = realSync;

// A service that removes itself inside `needsTick` must not still receive `tick`.
let ticks = 0;
let armed = false;
const selfRemove = {
  needsTick() { if (armed) root.removeTickable(selfRemove); return { periodMs: 1 }; },
  tick() { ticks++; },
};
root.addTickable(selfRemove);
armed = true;
root.tickLayers();
check("self-remove-skips-tick", ticks === 0 && !root.hasTickable(selfRemove));

// A repeated removal is safe, so a disposer can run twice.
root.addTickable(svc);
root.removeTickable(svc);
root.removeTickable(svc);
check("idempotent", !root.hasTickable(svc) && root.tickables.length === before);
