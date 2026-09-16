// yuke:jobs-ui — background jobs in the TUI: a status count, the /jobs list, and a live output view.
import { root } from "yuke:core";
import { ui, Window, NAV_KEYS } from "yuke:ui";
import { Pager } from "yuke:pager";
import { fs } from "yuke:fs";
import { strokeOf } from "yuke:keys";
import { list, get, stop } from "yuke:jobs";
import { focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { elapsedLabel } from "yuke:indicator";

/** @import { Context as PluginContext } from "yuke:ext" */
/** @import { InjectContext as Context } from "./types/ext.js" */
/** @import { Rect, HostMouseEvent } from "./types/core.js" */
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

// The view loads at most this much of a long log at a time, keeps at most this many lines, and cuts a longer line.
const OUTPUT_BYTES = 256 * 1024;
const OUTPUT_LINES = 5000;
const LINE_CHARS = 4096;

// A live view of one job log: each tick reads the bytes after the last read, and the pager follows the tail.
export class JobOutput {
  /** @param {Job} job @param {() => void} onClose */
  constructor(job, onClose) {
    this.job = job;
    this.onClose = onClose;
    this.pager = new Pager();
    /** @type {string[]} */
    this.lines = [];
    /** The unfinished last line; null marks a first read that began inside a line. */
    /** @type {string | null} */
    this.partial = "";
    /** Null until the first read picks a start near the end of the log. */
    /** @type {number | null} */
    this.offset = null;
    this.reading = false;
    this.again = false;
    /** @type {Rect} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  // Read the new bytes; a long log starts at a whole line near its end, a request during a read runs after it, and an ended job reads to the end.
  /** @returns {Promise<void>} */
  async read() {
    if (this.reading) { this.again = true; return; }
    this.reading = true;
    try {
      do {
        this.again = false;
        if (this.offset === null) {
          const { size } = await fs.readFrom(this.job.log, Number.MAX_SAFE_INTEGER, 1);
          this.offset = Math.max(0, size - OUTPUT_BYTES);
          if (this.offset > 0) this.partial = null;
        }
        const got = await fs.readFrom(this.job.log, this.offset, OUTPUT_BYTES);
        this.offset = got.next;
        this.append(got.text);
        if (this.job.state !== "running" && got.next < got.size && got.text !== "") this.again = true;
      } while (this.again);
    } finally {
      this.reading = false;
    }
  }

  /** @param {string} text */
  append(text) {
    if (text === "") return;
    const clean = text.replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, "").replace(/\t/g, "    ").replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
    const parts = ((this.partial ?? "") + clean).split("\n");
    if (this.partial === null) {
      // The first read began inside a line, so the view skips up to the first newline.
      if (parts.length === 1) return;
      parts.shift();
    }
    this.partial = /** @type {string} */ (parts.pop());
    if (this.partial.length > LINE_CHARS) {
      parts.push(this.partial.slice(0, LINE_CHARS));
      this.partial = "";
    }
    this.lines.push(...parts);
    if (this.lines.length > OUTPUT_LINES) this.lines.splice(0, this.lines.length - OUTPUT_LINES);
    const shown = this.partial === "" ? this.lines : [...this.lines, this.partial];
    this.pager.setRows(shown.map((line) => ({ text: line, group: "TxToolBody" })));
    root.invalidate();
  }

  /** @param {Rect} rect */
  layout(rect) { this.rect = rect; }

  draw() { this.pager.draw(this.rect); }

  /** @returns {{ periodMs: number } | null} */
  needsTick() { return this.job.state === "running" ? { periodMs: 500 } : null; }

  tick() { this.read().catch(failed); }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type !== "key" || event.event === "release") return true;
    const stroke = strokeOf(event);
    if (stroke === "esc" || stroke === "q") this.onClose();
    else if (stroke === "x" && this.job.state === "running") stop(this.job.id).catch(failed);
    else NAV_KEYS[stroke]?.(this.pager);
    root.invalidate();
    return true;
  }

  /** @param {HostMouseEvent} event @returns {boolean} */
  onMouse(event) { return this.pager.onMouse(event); }
}

/** @param {Context} ctx @param {Job} job */
export function openOutput(ctx, job) {
  /** @type {() => void} */
  let release = () => {};
  const view = new JobOutput(job, () => close());
  const win = new Window({
    title: () => view.job.id + " · " + jobState(view.job, Date.now()) + " · " + view.job.command, footer: "x stop · esc close",
    border: "rounded", width: (max) => Math.round(max * 0.9), height: (max) => Math.round(max * 0.8), content: view,
  });
  root.pushOverlay(win);
  release = ctx.tui.overlay(win);
  // The end of a job needs one last read, because its tick stops with the run.
  const off = ctx.on("jobs.changed", (/** @type {Job} */ changed) => {
    if (changed.id !== job.id) return;
    view.job = changed;
    view.read().catch(failed);
  });
  let alive = true;
  const cleanup = ctx.effect(() => () => close());
  function close() {
    if (!alive) return;
    alive = false;
    off(); release(); cleanup();
  }
  view.read().catch(failed);
  return view;
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
    onAccept: (job) => { close(); openOutput(ctx, get(job.id) ?? job); },
    onCancel: () => close(),
    keymap: {
      x: (_event, content) => { const job = content.list.selected(); if (job && job.state === "running") stop(job.id).catch(failed); },
      X: () => {
        const running = items.filter((j) => j.state === "running");
        Promise.all(running.map((j) => stop(j.id))).then((ended) => notice.show("jobs · stopped " + ended.filter((j) => j?.state === "stopped").length), failed);
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
  return { ...picker, close };
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
