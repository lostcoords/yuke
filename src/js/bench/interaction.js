import { Context, Scope, plugins, scopeOf } from "yuke:ext";
import { root } from "yuke:core";
import { tuiPlugin } from "yuke:tui";
import { tuiInteractionPlugin } from "yuke:interaction-ui";

plugins.use(tuiPlugin);
plugins.use(tuiInteractionPlugin);
const scope = new Scope("bench-interaction");
const reused = new Context(scope, "bench-interaction");
/** @type {HostEvent} */
const enter = { type: "key", code: "enter", char: "", shifted: "", baseLayout: "", text: "", event: "press", mods: 0 };
let fresh = false;
let count = 0;

async function step() {
  const ctx = fresh ? new Context(new Scope("fresh-interaction"), "bench-interaction") : reused;
  try {
    const answer = ctx.interaction.confirm("Continue?", "Benchmark the shared prompt lifecycle.");
    root.onEvent(enter);
    if (await answer !== true) throw new Error("the prompt has no answer");
    if (root.overlays.length !== 0) throw new Error("the prompt remains open");
    return ++count;
  } finally {
    if (fresh) scopeOf(ctx).dispose();
  }
}

globalThis.bench = {
  /** @param {string} phase */
  async start(phase) {
    fresh = phase === "interaction_fresh";
    await step();
    count = 0;
    return 1;
  },
  step,
  verify() {
    if (root.overlays.length !== 0) throw new Error("a prompt remains open");
    return count;
  },
};
