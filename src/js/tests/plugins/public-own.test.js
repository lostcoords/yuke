import { check, equal } from "yuke:internal/test";
import { plugins } from "yuke";
import { command } from "yuke:internal/core";
import { tuiPlugin } from "yuke:internal/tui";

const definition = { name: "owned", description: "Read a note.", parameters: { type: "object", properties: {} }, execute: async () => "note" };
let runs = 0;
const owner = plugins.use({ name: "public-owner", apply(ctx) {
  ctx.tools.define(definition);
  ctx.inject(["tui"], (ctx) => {
    ctx.tui.command(null, { note: () => { runs++; } });
  });
} });
// The name is taken while its owner lives, and free again once the owner is gone.
let rejected = false;
try { plugins.use({ name: "second-owner", apply(ctx) { ctx.tools.define(definition); } }); } catch { rejected = true; }
check("owner-keeps-its-tool-name", rejected);
check("command-waits-for-tui", !command.available("public-owner:note"));
const terminal = plugins.use(tuiPlugin);
command.perform("public-owner:note");
equal(runs, 1);
owner.dispose();
const again = plugins.use({ name: "third-owner", apply(ctx) { ctx.tools.define(definition); } });
again.dispose();
check("command-leaves-with-plugin", !command.available("public-owner:note"));
terminal.dispose();
