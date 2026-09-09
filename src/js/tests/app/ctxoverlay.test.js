import { check } from "yuke:test";
import { command, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { tui } from "yuke:tui";
const layer = (n) => ({ name: n, rect: { x: 0, y: 0, w: 1, h: 1 }, layout() {}, draw() {} });

const owner = { name: "ov", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "ov:open": () => t.overlay(root.pushOverlay(layer("own"))) }); } };
const other = { name: "other", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "other:open": () => root.pushOverlay(layer("other")) }); } };
const base = root.overlays.length;

plugins.use(owner);
plugins.use(other);

// Two overlays from one plugin both leave with it, and an unowned one stays.
command.perform("ov:open");
command.perform("ov:open");
command.perform("other:open");
check("three-open", root.overlays.length === base + 3);
plugins.dispose("ov");
check("owned-popped", root.overlays.length === base + 1);
check("unowned-kept", root.overlays[root.overlays.length - 1].name === "other");
root.popOverlay();
plugins.dispose("other");

// One plugin's unload must leave another plugin's overlay alone, not every owned overlay.
const second = { name: "ov2", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "ov2:open": () => t.overlay(root.pushOverlay(layer("own2"))) }); } };
plugins.use(owner);
plugins.use(second);
command.perform("ov:open");
command.perform("ov2:open");
plugins.dispose("ov");
check("other-owner-kept", root.overlays.length === base + 1 && root.overlays[root.overlays.length - 1].name === "own2");
plugins.dispose("ov2");
check("second-owner-popped", root.overlays.length === base);

// A reload owns its own overlays, and the disposed scope no longer reaches the stack.
plugins.use(owner);
command.perform("ov:open");
const kept = root.pushOverlay(layer("kept"));
plugins.dispose("ov");
check("reload-pops-its-own", root.overlays.length === base + 1);
check("reload-keeps-others", root.overlays[root.overlays.length - 1] === kept);
root.popOverlay(kept);

// An overlay the user already closed is not popped again, so an unload cannot take a later one.
plugins.use(owner);
command.perform("ov:open");
root.popOverlay();
const after = root.pushOverlay(layer("after"));
plugins.dispose("ov");
check("closed-overlay-not-repopped", root.overlays.length === base + 1 && root.overlays[root.overlays.length - 1] === after);
root.popOverlay(after);

// The map keys on the layer, so a plugin that pushes one twice still owns the second push.
const again = layer("again");
plugins.use({ name: "re", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { "re:open": () => t.overlay(root.pushOverlay(again)) }); } });
command.perform("re:open");
root.popOverlay(again);
root.pushOverlay(again);
plugins.dispose("re");
check("re-push-stays-owned", root.overlays.length === base);

// A layer that never reached the stack is a caller error, such as a picker handle in place of its window.
let threw = false;
plugins.use({ name: "bad", apply(ctx) { const t = tui.bindTo(ctx); try { t.overlay(layer("loose")); } catch (e) { threw = true; } } });
check("rejects-a-layer-off-the-stack", threw && root.overlays.length === base);
plugins.dispose("bad");

// The overlay cleanup keeps its place among the plugin's own effects, so the order stays LIFO.
const seen = [];
plugins.use({ name: "ord", apply(ctx) {
  const t = tui.bindTo(ctx);
  const a = root.pushOverlay(layer("a"));
  t.overlay(a);
  ctx.effect(() => () => seen.push(root.overlays.indexOf(a) >= 0));
  t.overlay(root.pushOverlay(layer("b")));
} });
plugins.dispose("ord");
check("cleanup-keeps-its-disposer-slot", seen.length === 1 && seen[0] === true);
check("order-test-left-nothing", root.overlays.length === base);

// A frozen layer must still be claimable, so the claim never writes to the layer itself.
const frozen = Object.freeze({ name: "frozen", rect: { x: 0, y: 0, w: 1, h: 1 }, layout() {}, draw() {} });
plugins.use({ name: "fz", apply(ctx) { const t = tui.bindTo(ctx); t.overlay(root.pushOverlay(frozen)); } });
check("frozen-claimed", root.overlays.length === base + 1);
plugins.dispose("fz");
check("frozen-popped", root.overlays.length === base);

// A duplicate push rejects the second mount and preserves the first owner.
const twice = layer("twice");
let duplicateRejected = false;
plugins.use({ name: "dup", apply(ctx) {
  const t = tui.bindTo(ctx);
  t.overlay(root.pushOverlay(twice));
  try { root.pushOverlay(twice); } catch (error) { duplicateRejected = error instanceof TypeError; }
} });
check("duplicate-rejected", duplicateRejected && root.overlays.length === base + 1);
plugins.dispose("dup");
check("duplicate-owner-popped", root.overlays.length === base);

// A late push from a disposed plugin closes at once, because a dead scope can never revert it.
let late = null;
plugins.use({ name: "late", apply(ctx) { const t = tui.bindTo(ctx); late = () => t.overlay(root.pushOverlay(layer("late"))); } });
plugins.dispose("late");
late();
check("dead-scope-closes-a-late-push", root.overlays.length === base);
