// A plugin as a user writes it, checked against the generated yuke.d.ts alone.
import { defineConfig, plugins, fs, exec, events } from "yuke";
import { ui } from "yuke:ui";
import { labels } from "yuke:chat";
import { currentSession } from "yuke:session";
import { agents } from "yuke:plugins";
// @ts-expect-error Internal modules stay private; the loader rejects them too.
import { scopeOf } from "yuke:internal/ext";

/** @type {import("yuke").Plugin} */
const demo = {
  name: "demo",
  apply(ctx) {
    ctx.on("session.changed", () => {});
    ctx.on("demo:ping", (count) => count.toFixed());
    ctx.tools.define({ name: "t", description: "d", parameters: {}, execute: async (args, _signal, context) => [args, context.workspaceRoot] });
    ctx.inject(["tui"], (c) => {
      c.tui.command.add("demo:pick", { desc: "pick one", run: () => { c.tui.overlay(ui.pick({ items: ["a"] }).win); } });
    });
    ctx.inject(["chat"], (c) => c.chat.labels({ sources: { engine_interruption: (source) => "run " + source.run_id } }));
  },
};
plugins.use(demo);
plugins.use(agents({ catalog: { research: { tools: ["read"] } }, maxDepth: 2 }));
fs.readFile("x", { workspaceRoot: "/tmp" }).then((text) => text.toUpperCase());
exec("true", { workspaceRoot: "/tmp" }).then((result) => result.code);
new Promise((resolve) => setTimeout(resolve, 1));
labels.role;
currentSession()?.sessionId;
// @ts-expect-error A merged event checks its arguments.
events.emit("demo:ping", "one");
// @ts-expect-error The root is an option, not a positional argument.
fs.readFile("x", "/tmp");
// @ts-expect-error A label names an engine source type.
plugins.use({ name: "x", apply(ctx) { ctx.inject(["chat"], (c) => c.chat.labels({ sources: { run_interrupted: () => "" } })); } });
// @ts-expect-error The host owns the event entry point.
onEvent;
// @ts-expect-error An internal namespace is not a global.
$ext;
// @ts-expect-error The config has no agents key; agent limits belong to the agents plugin.
defineConfig({ agents: {} });
export default defineConfig({ mouse: { scrollLines: 5 } });
