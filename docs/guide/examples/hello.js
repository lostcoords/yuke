// Save this entry as plugins/hello/index.js, and list ./plugins/hello in config.json.
// plugin.json: {"name": "hello", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// The command runs in the TUI. `yuke check` loads it without a terminal.

/** Add a hello command when TUI is available. A failed registration throws. @param {import("yuke").Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;
  tui.command.add("hi", {
    desc: "Say hi",
    slash: true,
    run: () => { ctx.interaction.notify("hi from hello"); },
  });
  ctx.print("hello loaded");
}
