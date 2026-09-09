import { check } from "yuke:test";
import { command, keymap, root } from "yuke:core";
import { plugins } from "yuke:ext";
import { commandUiPlugin } from "yuke:command-ui";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);

check("absent-before-load", !command.available("ui:palette"));

plugins.use(commandUiPlugin);
check("commands-registered", command.available("ui:palette"));
// The binding must name the palette, not merely exist.
check("key-bound", (keymap.describe("ctrl+p").winner || {}).binding === "ui:palette");

const before = root.overlays.length;
command.perform("ui:palette");
check("palette-opens", root.overlays.length === before + 1);
root.popOverlay();

plugins.dispose("command-ui");
check("unload-drops-commands", !command.available("ui:palette"));
check("unload-drops-key", keymap.describe("ctrl+p").winner === null);

// An unload must take this module's open overlays with it, or they keep taking keys.
plugins.use(commandUiPlugin);
command.perform("ui:palette");
check("palette-open-again", root.overlays.length === before + 1);
plugins.dispose("command-ui");
check("unload-pops-overlay", root.overlays.length === before);
