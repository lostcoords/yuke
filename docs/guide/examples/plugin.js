// A complete plugin entry. Save it as index.js in a plugin folder with this plugin.json, and list the folder in config.json.
// plugin.json: {"name": "example", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// CI type-checks this file against yuke.d.ts, so each call here matches the current API.
/** @import { Context } from "yuke" */

let sent = 0;
let completed = 0;

/** @param {Context} ctx */
export default function (ctx) {
  // A model tool. The model can send any JSON. This tool checks the argument and throws for a bad value.
  ctx.tools.define({
    name: "word_count",
    description: "Count the words in a text.",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"], additionalProperties: false },
    async execute(args) {
      const text = typeof args === "object" && args !== null && "text" in args ? args.text : undefined;
      if (typeof text !== "string") throw new Error("text must be a string");
      return String(text.split(/\s+/).filter(Boolean).length);
    },
  });

  // An engine hook. It blocks one shell command and lets every other tool call run.
  ctx.hook("tool.before", (call) => {
    if (call.name === "exec" && call.arguments.includes("rm -rf /")) return { block: "the example plugin refuses rm -rf /" };
    return undefined;
  });

  ctx.hook("input.before", () => { sent++; return undefined; });

  // An engine fact event passes the whole drain. This listener exists in every mode.
  ctx.on("run.done", (drain) => {
    if (drain.type === "session") completed++;
  });

  // The TUI parts. `yuke -p` and `yuke --rpc` have no `tui`, so they stop here.
  const tui = ctx.get("tui");
  if (!tui) return;
  // A bare name becomes `example:hello`. A `desc` lists it in the ctrl+p palette, and `slash` adds /hello.
  tui.command.add("hello", { desc: "Say hello", slash: true, run: () => { ctx.interaction.notify("hello from example"); } });
  tui.keymap.add({ "ctrl+g": "example:hello" });
  tui.status.add({ side: "right", render: () => (sent > 0 ? "sent " + sent + " · done " + completed : undefined) });
}
