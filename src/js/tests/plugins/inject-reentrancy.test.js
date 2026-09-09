import { check } from "yuke:test";
import { plugins, services, Scope } from "yuke:ext";

// The killer registers its watcher first, so it runs before the victim in one change.
const log = [];
plugins.use({ name: "killer", apply: (ctx) => ctx.inject(["c"], () => { plugins.dispose("victim"); }) });
plugins.use({ name: "victim", apply: (ctx) => ctx.inject(["c"], () => { log.push("on"); return () => log.push("off"); }) });
services.provide("c", 1);
// The victim died during the same change, so its copied watcher must build nothing.
check("no-orphan-build", log.join(",") === "");
check("victim-gone", !plugins.get("victim"));

// A block that drops its own dependency must not stay active.
// The provider exists first, so the block builds at once and can withdraw it from inside.
const seen = [];
const offY = services.provide("y", 1);
plugins.use({
  name: "self-cut",
  apply: (ctx) => ctx.inject(["y"], () => {
    offY();
    seen.push("built");
    return () => seen.push("torn");
  }),
});
check("dependency-gone", !services.has("y"));
check("block-torn-down", seen.join(",") === "built,torn");

// A scope disposed inside its own effect reverts that effect at once.
const s = new Scope("reentrant");
let cleaned = 0;
s.effect(() => { s.dispose(); return () => { cleaned = 1; }; });
check("reentrant-cleanup", cleaned === 1);
