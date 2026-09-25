import { check } from "yuke:internal/test";
import { command, root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { explorerPlugin } from "yuke:internal/explorer";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);

check("absent-before-load", !command.available("app:explorer"));
plugins.use(explorerPlugin);
check("command-registered", command.available("app:explorer"));

// The command must open it, so a broken command entry cannot pass.
const before = root.overlays.length;
command.perform("app:explorer");
check("command-opens-overlay", root.overlays.length === before + 1);

// An unload takes an OPEN picker off the stack, or it keeps eating every key.
plugins.dispose("explorer");
check("unload-pops-open-picker", root.overlays.length === before);
check("unload-drops-command", !command.available("app:explorer"));

// A reload opens and closes cleanly again.
plugins.use(explorerPlugin);
command.perform("app:explorer");
check("reload-opens", root.overlays.length === before + 1);
root.popOverlay();
check("closes-again", root.overlays.length === before);
plugins.dispose("explorer");
