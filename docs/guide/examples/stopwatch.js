// Time an interval in the status bar. This plugin needs no service in `uses`.

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;

  let started = 0;
  let elapsed = 0;
  let running = false;
  /** @type {() => void} */
  let cancel = () => {};

  const update = () => {
    const duration = elapsed + (running ? tui.now() - started : 0);
    tui.status.set("time", {
      text: `${Math.floor(duration / 1000)}s`,
      side: "right",
      order: 20,
    });
    if (running) cancel = tui.after(1000, update);
  };

  tui.commands.add({
    name: "toggle",
    description: "Start or stop the stopwatch",
    run: () => {
      cancel();
      if (running) elapsed += tui.now() - started;
      else started = tui.now();
      running = !running;
      update();
    },
  });
  tui.commands.add({
    name: "reset",
    description: "Reset the stopwatch",
    run: () => {
      cancel();
      elapsed = 0;
      started = tui.now();
      update();
    },
  });
  update();
  return undefined;
}
