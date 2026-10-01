// A complete plugin for a yuke profile. Copy it next to index.js and import it: `import "./plugin.js";`.
// CI type-checks this file against yuke.d.ts, so each call here matches the current API.
import { plugins } from "yuke";

let sent = 0;
let completed = 0;

plugins.use({
  name: "example",
  apply(ctx) {
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

    // The TUI parts. This block runs only while the TUI exists, so `yuke -p` and `yuke --rpc` skip it.
    ctx.inject(["tui"], (c) => {
      // A bare name becomes `example:hello`. A `desc` lists it in the ctrl+p palette, and `slash` adds /hello.
      c.tui.command.add("hello", { desc: "Say hello", slash: true, run: () => { c.interaction.notify("hello from example"); } });
      c.tui.keymap.add({ "ctrl+g": "example:hello" });
      c.tui.status.add({ side: "right", render: () => (sent > 0 ? "sent " + sent + " · done " + completed : null) });
    });
  },
});
