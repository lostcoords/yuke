import { check, equal } from "yuke:test";
import { plugins, tools } from "yuke";
import { command } from "yuke:core";
import { tuiPlugin } from "yuke:tui";

const definition = { name: "owned", description: "Read a note.", parameters: { type: "object", properties: {} }, execute: async () => "note" };
const first = tools.define(definition);
first();
const second = tools.define(definition);
first();
let rejected = false;
try { tools.define(definition); } catch { rejected = true; }
check("old-disposer-keeps-new-tool", rejected);
second();

let runs = 0;
const off = plugins.use({ name: "public-owner", apply(ctx) {
  ctx.tools.define(definition);
  ctx.inject(["tui"], (ctx) => {
    ctx.tui.command(null, { note: () => { runs++; } });
  });
} });
check("command-waits-for-tui", !command.available("public-owner:note"));
const terminal = plugins.use(tuiPlugin);
command.perform("public-owner:note");
equal(runs, 1);
off.dispose();
const afterUnload = tools.define(definition);
afterUnload();
check("command-leaves-with-plugin", !command.available("public-owner:note"));
terminal.dispose();
