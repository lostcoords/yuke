// A plugin as a user writes it, checked against the generated yuke.d.ts alone.
import { defineConfig, plugins, fs, exec, events } from "yuke";
import { ui } from "yuke:ui";
import { inputSourceLabel } from "yuke:chat";
import { currentSession } from "yuke:session";
import { agents } from "yuke:plugins";
// @ts-expect-error Internal modules stay private; the loader rejects them too.
import { scopeOf } from "yuke:internal/ext";

const adder = {
  step: 1,
  /** @param {number} n */
  add: (n) => n + 1,
};

/** @type {import("yuke").Plugin} */
const demo = {
  name: "demo",
  apply(ctx) {
    ctx.on("session.changed", () => {});
    ctx.on("demo:ping", (count) => count.toFixed());
    ctx.tools.define({ name: "t", description: "d", parameters: {}, execute: async (args, _signal, context) => JSON.stringify([args, context.workspaceRoot]) });
    ctx.inject(["tui"], (c) => {
      c.tui.command.add("demo:pick", { desc: "pick one", run: () => { c.tui.overlay(ui.pick({ items: ["a"] }).win); } });
    });
    ctx.inject(["chat"], (c) => c.chat.render({ sources: { engine_interruption: (source) => "run " + source.run_id } }));
    ctx.provide("counter", { count: () => 1 });
    ctx.inject(["counter"], (c) => c.counter.count().toFixed());
    ctx.advise(adder, "add", "filterReturn", (sum) => sum * 2);
    ctx.advise(adder, "add", "around", function (next, n) { return next(n + this.step); });
    // @ts-expect-error A declared capability checks its provider.
    ctx.provide("counter", 1);
    // @ts-expect-error A context member cannot be a capability name.
    ctx.inject(["interaction"], () => {});
    // @ts-expect-error Advice names a method of the target.
    ctx.advise(adder, "ad", "before", () => {});
    // @ts-expect-error An around advice takes the parameters of the method.
    ctx.advise(adder, "add", "around", /** @param {(n: number) => number} next @param {string} n */ (next, n) => next(n.length));
  },
};
plugins.use(demo);
plugins.use(agents({ catalog: { research: { tools: ["read"] } }, maxDepth: 2 }));
fs.readFile("x", { workspaceRoot: "/tmp" }).then((text) => text.toUpperCase());
exec("true", { workspaceRoot: "/tmp" }).then((result) => result.code);
new Promise((resolve) => setTimeout(resolve, 1));
inputSourceLabel(null).length;
currentSession()?.sessionId;
// @ts-expect-error A merged event checks its arguments.
events.emit("demo:ping", "one");
// @ts-expect-error The root is an option, not a positional argument.
fs.readFile("x", "/tmp");
// @ts-expect-error A label names an engine source type.
plugins.use({ name: "x", apply(ctx) { ctx.inject(["chat"], (c) => c.chat.render({ sources: { run_interrupted: () => "" } })); } });
// @ts-expect-error The host owns the event entry point.
onEvent;
// @ts-expect-error An internal namespace is not a global.
$ext;
// @ts-expect-error The config has no agents key; agent limits belong to the agents plugin.
defineConfig({ agents: {} });
export default defineConfig({ mouse: { scrollLines: 5 } });
