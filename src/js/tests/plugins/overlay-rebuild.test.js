import { check } from "yuke:test";
import { root } from "yuke:core";
import { plugins, services } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);

// One long-lived layer, claimed by a block that also waits on a second capability.
const layer = { name: "kept", rect: { x: 0, y: 0, w: 1, h: 1 }, layout() {}, draw() {} };
root.pushOverlay(layer);
const base = root.overlays.length;

let builds = 0;
services.provide("gate", 1);
plugins.use({
  name: "keeper",
  apply: (ctx) => ctx.inject(["tui", "gate"], (c) => { builds += 1; c.tui.overlay(layer); }),
});
check("claimed", builds === 1 && root.overlays.indexOf(layer) >= 0);

// A change of the second capability rebuilds the block; the layer must pass across.
services.provide("gate", 2);
check("rebuilt", builds === 2);
check("layer-kept", root.overlays.indexOf(layer) >= 0);
check("no-duplicate", root.overlays.length === base);

// The plugin still owns it, so an unload takes the layer off the stack.
plugins.dispose("keeper");
check("released", root.overlays.indexOf(layer) < 0);
