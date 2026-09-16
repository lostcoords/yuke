// yuke:jobs-ui — background jobs in the TUI: a status count and the /jobs list.
import { root } from "yuke:core";
import { ui } from "yuke:ui";
import { list, stop } from "yuke:jobs";
import { focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { elapsedLabel } from "yuke:indicator";

/** @import { Context as PluginContext } from "yuke:ext" */
/** @import { InjectContext as Context } from "./types/ext.js" */
/** @typedef {import("yuke:jobs").Job} Job */

/** @param {unknown} error */
function failed(error) { notice.show("jobs · " + (/** @type {Error} */ (error)?.message || String(error))); }

/** @param {Job} job @param {number} now @returns {string} */
export function jobState(job, now) {
  if (job.state === "running") return "running " + elapsedLabel(now - job.startedAt);
  if (job.state === "stopped") return "stopped";
  return job.signal !== null ? "signal " + job.signal : "exit " + job.code;
}

/** @param {Job[]} jobs @returns {string} */
function summary(jobs) {
  const running = jobs.filter((j) => j.state === "running").length;
  return "Jobs · " + running + " running · " + (jobs.length - running) + " ended";
}

// The list shows every job of this process, newest first, and marks the jobs of the focused session.
/** @param {Context} ctx */
export function openJobs(ctx) {
  const current = focusedChat()?.sessionId;
  const rows = () => list().reverse();
  let items = rows();
  const picker = ui.select(items, {
    title: summary(items), footer: "↵ output · x stop · X stop all · esc close",
    border: "rounded", width: (max) => Math.round(max * 0.9), height: (max) => Math.round(max * 0.6),
    key: (job) => job.id,
    format: (job) => ({ marker: job.state === "running" ? "•" : "·", indent: 2, text: job.id + "  " + job.command, detail: job.sessionId === current ? "this session" : "", right: jobState(job, Date.now()) }),
    // The output view replaces this in the next slice; the log path is the output until then.
    onAccept: (job) => notice.show("jobs · " + job.id + " log · " + job.log),
    onCancel: () => close(),
    keymap: {
      x: (_event, content) => { const job = content.list.selected(); if (job && job.state === "running") stop(job.id).catch(failed); },
      X: () => {
        const running = items.filter((j) => j.state === "running");
        Promise.all(running.map((j) => stop(j.id))).then(() => notice.show("jobs · stopped " + running.length), failed);
      },
    },
  });
  const release = ctx.tui.overlay(picker.win);
  const offChanged = ctx.on("jobs.changed", () => {
    items = rows();
    picker.win.opts.title = summary(items);
    picker.content.setSource(items);
    root.invalidate();
  });
  // A running job shows its age, so the list repaints each second while one runs.
  const timer = setInterval(() => { if (items.some((j) => j.state === "running")) root.invalidate(); }, 1000);
  let alive = true;
  const cleanup = ctx.effect(() => () => close());
  function close() {
    if (!alive) return;
    alive = false;
    clearInterval(timer);
    offChanged(); release(); cleanup();
  }
  return picker;
}

export const jobsUiPlugin = {
  name: "jobs-ui",
  /** @param {PluginContext} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The count changes only on `jobs.changed`, so a paint reads a number and copies no job.
      let running = list().filter((j) => j.state === "running").length;
      ctx.on("jobs.changed", () => {
        running = list().filter((j) => j.state === "running").length;
        root.invalidate();
      });
      ctx.tui.status({ side: "right", order: 1, render: () => (running === 0 ? "" : "jobs " + running) });
      ctx.tui.command(null, {
        "jobs:open": () => openJobs(ctx),
      }, { "jobs:open": { title: "Jobs", description: "see or stop background jobs", slash: "jobs" } });
    });
  },
};
