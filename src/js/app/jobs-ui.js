// yuke:jobs-ui — background jobs in the TUI.
import { root } from "yuke:core";
import { list } from "yuke:jobs";

/** @import { Context } from "yuke:ext" */

export const jobsUiPlugin = {
  name: "jobs-ui",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The count changes only on `jobs.changed`, so a paint reads a number and copies no job.
      let running = list().filter((j) => j.state === "running").length;
      ctx.on("jobs.changed", () => {
        running = list().filter((j) => j.state === "running").length;
        root.invalidate();
      });
      ctx.tui.status({ side: "right", order: 1, render: () => (running === 0 ? "" : `jobs ${running}`) });
    });
  },
};
