// Save this entry as index.js in a plugin folder, and list the folder in config.json.
// plugin.json: {"name": "lifecycle", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// This TUI example uses the POSIX commands cat, sleep, and printf. `yuke check` starts and stops its child too.
import { exec, spawn } from "yuke";

/** Own a timer and a child process until unload. A failed registration throws; command failures become notifications. @param {import("yuke").Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;

  // An effect owns synchronous cleanup, not a promise.
  ctx.effect(() => {
    const timer = setTimeout(() => { ctx.print("lifecycle still loaded"); }, 10000);
    return () => { clearTimeout(timer); };
  });

  // The child waits for input until unload kills it and waits for its exit.
  const child = spawn(["cat"]);
  ctx.own(async () => {
    child.kill();
    await child.exited;
  });
  void child.exited.catch((error) => {
    if (ctx.alive) ctx.interaction.notify("child failed: " + String(error), "error");
  });

  tui.command.add("probe", {
    desc: "Run one cancelable command",
    slash: true,
    async run() {
      try {
        const result = await exec("sleep 1; printf 'probe done\\n'", { signal: ctx.signal, timeoutMs: 5000 });
        if (!ctx.alive) return;
        if (result.code !== 0) throw new Error("probe did not exit successfully");
        ctx.interaction.notify(result.stdout.trim());
      } catch (error) {
        if (ctx.alive) ctx.interaction.notify(String(error), "error");
      }
    },
  });
}
