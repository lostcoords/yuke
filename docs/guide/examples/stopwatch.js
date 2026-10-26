// Save this entry as index.js in a plugin folder, and list the folder in config.json.
// plugin.json: {"name": "stopwatch", "extensions": {"sh.yuke": {"entry": "./index.js", "uses": ["tui"]}}}
// This clock uses wall time, not provider speed or a monotonic time source.

/** Add a frame-loop clock in the TUI. Null TUI skips registration. A failed registration throws. @param {import("yuke").Context} ctx */
export default function (ctx) {
  const tui = ctx.get("tui");
  if (!tui) return;

  let running = false;
  let startedAt = 0;
  let seconds = 0;
  let label = "0s";
  const period = { periodMs: 1000 };
  const update = () => {
    if (!running) return;
    const next = Math.floor(Math.max(0, Date.now() - startedAt) / 1000);
    if (next === seconds) return;
    seconds = next;
    label = next + "s";
  };

  tui.command.add("clock-start", {
    desc: "Start or reset the clock",
    slash: true,
    run: () => {
      startedAt = Date.now();
      seconds = 0;
      label = "0s";
      running = true;
      tui.root.invalidatePaint();
    },
  });
  tui.command.add("clock-stop", {
    desc: "Freeze the clock",
    slash: true,
    run: () => {
      update();
      running = false;
      tui.root.invalidatePaint();
    },
  });
  tui.status.add({ side: "right", render: () => label });
  tui.tickable({ needsTick: () => running ? period : null, tick: update });
}
