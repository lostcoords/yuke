// Choose a review focus. This plugin needs no service in `uses`.

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  const tui = ctx.get("tui");
  if (!tui) return undefined;

  tui.commands.add({
    name: "focus",
    description: "Choose a review focus",
    run: async () => {
      const item = await tui.select({
        title: "Review focus",
        items: [{ label: "Correctness" }, { label: "Performance" }, { label: "Tests" }],
        label: (item) => item.label,
        signal: ctx.signal,
      });
      if (item) {
        tui.status.set("focus", { text: item.label, side: "left", order: 20 });
      }
    },
  });
  return undefined;
}
