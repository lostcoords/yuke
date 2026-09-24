// yuke:jobs-ui — background jobs in the TUI: a status count, the /jobs list, and a live output view.
import { root } from "yuke:core";
import { ui, Window, ScrollView } from "yuke:ui";
import { list, get, stop, read, name, endLabel, shortCommand } from "yuke:jobs";
import { focusedChat } from "yuke:chat";
import { notice } from "yuke:notice";
import { errorText } from "yuke:format";
import { elapsedLabel } from "yuke:indicator";

/** @import { Context as PluginContext } from "yuke:ext" */
/** @import { InjectContext as Context } from "./types/ext.js" */
/** @import { Job } from "yuke:jobs-native" */
/** @import { TranscriptRow } from "./types/pager.js" */

/** @param {unknown} error */
function failed(error) { notice.show("jobs · " + errorText(error)); }

/** @param {Job} job @param {number} now @returns {string} */
function jobState(job, now) {
  return job.state === "running" && !job.stop_requested ? "running " + elapsedLabel(now - job.started_at_ms) : endLabel(job);
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
export class JobOutput extends ScrollView {
  /** @param {Job} job @param {() => void} onClose */
  constructor(job, onClose) {
    super(onClose);
    this.job = job;
    /** @type {TranscriptRow[]} */
    this.rows = [];
    this.first = 0;
    this.complete = false;
    this.closed = false;
    this.pager.setSource({
      rowCount: () => Math.min(OUTPUT_LINES, this.rows.length + (this.partial ? 1 : 0)) + (this.complete ? 1 : 0),
      rows: (_width, top, height) => {
        const skip = this.partial && this.rows.length === OUTPUT_LINES ? 1 : 0;
        const count = this.rows.length - skip;
        const end = count + (this.partial ? 1 : 0);
        const shown = [];
        for (let i = top; i < Math.min(top + height, end + (this.complete ? 1 : 0)); i++) {
          if (i < count) shown.push(/** @type {TranscriptRow} */ (this.rows[(this.first + skip + i) % this.rows.length]));
          else shown.push({ text: i < end ? this.partial ?? "" : `[${endLabel(this.job)}]`, group: "TxToolBody" });
        }
        return shown;
      },
    });
    /** The unfinished last line; null marks a first read that began inside a line. */
    /** @type {string | null} */
    this.partial = "";
    /** Null until the first read picks a start near the end of the log. */
    /** @type {number | null} */
    this.offset = null;
    this.reading = false;
    this.again = false;
  }

  // Read the new bytes; a long log starts at a whole line near its end, a request during a read runs after it, and an ended job reads to the end.
  /** @returns {Promise<void>} */
  async read() {
    if (this.closed) return;
    if (this.reading) { this.again = true; return; }
    this.reading = true;
    try {
      do {
        this.again = false;
        const got = await read(this.job.id, this.offset, OUTPUT_BYTES);
        if (this.closed) return;
        if (this.offset === null && got.start > 0) this.partial = null;
        this.offset = got.next;
        this.append(got.text);
        this.complete = got.complete;
        if (this.complete) root.invalidate();
        if (this.job.state !== "running" && !got.complete && got.next < got.size && got.text !== "") this.again = true;
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
    this.partial = /** @type {string} */ (parts.pop()).slice(0, LINE_CHARS);
    for (const line of parts) {
      const row = { text: line.slice(0, LINE_CHARS), group: "TxToolBody" };
      if (this.rows.length < OUTPUT_LINES) this.rows.push(row);
      else {
        this.rows[this.first] = row;
        this.first = (this.first + 1) % OUTPUT_LINES;
      }
    }
    root.invalidate();
  }

  /** @returns {{ periodMs: number } | null} */
  needsTick() { return this.job.state === "running" ? { periodMs: 500 } : null; }

  tick() { this.read().catch(failed); }

  /** @param {string} stroke @returns {boolean} */
  onStroke(stroke) {
    if (stroke !== "x" || this.job.state !== "running") return false;
    stop(this.job.id).catch(failed);
    return true;
  }
}

/** @param {Context} ctx @param {Job} job */
export function openOutput(ctx, job) {
  const view = new JobOutput(job, () => close());
  const win = new Window({
    title: () => name(view.job) + " · " + jobState(view.job, Date.now()) + " · " + shortCommand(view.job.command), footer: "x stop · esc close",
    border: "rounded", width: (max) => Math.round(max * 0.9), height: (max) => Math.round(max * 0.8), content: view,
  });
  // The end of a job needs one last read, because its tick stops with the run.
  const off = ctx.on("jobs.changed", (/** @type {Job} */ changed) => {
    if (changed.id !== job.id) return;
    view.job = changed;
    view.read().catch(failed);
  });
  const close = ctx.tui.overlay(win, () => { view.closed = true; off(); });
  view.read().catch(failed);
  return view;
}

// The list shows every job of this process, newest first, and marks the jobs of the focused session.
/** @param {Context} ctx */
export function openJobs(ctx) {
  const current = focusedChat()?.sessionId;
  let items = list();
  const picker = ui.select(items, {
    title: summary(items), footer: "↵ output · x stop · X stop all · esc close",
    border: "rounded", width: (max) => Math.round(max * 0.9), height: (max) => Math.round(max * 0.6),
    key: (job) => job.id,
    format: (job) => ({ marker: job.state === "running" ? "•" : "·", indent: 2, text: name(job) + "  " + shortCommand(job.command) + "  ", detail: (job.session_id ?? null) === (current ?? null) ? "this session" : "", right: jobState(job, Date.now()) }),
    onAccept: (job) => { close(); openOutput(ctx, get(job.id) ?? job); },
    onCancel: () => close(),
    keymap: {
      x: (_event, content) => { const job = content.list.selected(); if (job && job.state === "running") stop(job.id).catch(failed); },
      X: () => {
        const running = items.filter((j) => j.state === "running");
        Promise.all(running.map((j) => stop(j.id))).then((ended) => notice.show("jobs · stop requested for " + ended.filter((j) => j?.stop_requested).length), failed);
      },
    },
  });
  const offChanged = ctx.on("jobs.changed", () => {
    items = list();
    picker.win.opts.title = summary(items);
    picker.content.setSource(items);
    root.invalidate();
  });
  // A running job shows its age, so the list repaints each second while one runs.
  const timer = setInterval(() => { if (items.some((j) => j.state === "running")) root.invalidate(); }, 1000);
  const close = ctx.tui.overlay(picker.win, () => { clearInterval(timer); offChanged(); });
  return { ...picker, close };
}

export const jobsUiPlugin = {
  name: "jobs-ui",
  /** @param {PluginContext} ctx */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The event carries the job, so the count follows it and a paint copies no table.
      const running = new Set(list().filter((j) => j.state === "running").map((j) => j.id));
      ctx.on("jobs.changed", (/** @type {Job} */ job) => {
        if (job.state === "running") running.add(job.id);
        else running.delete(job.id);
        root.invalidate();
      });
      ctx.tui.status({ side: "right", order: 1, render: () => (running.size === 0 ? "" : "jobs " + running.size) });
      ctx.tui.command(null, {
        "jobs:open": () => openJobs(ctx),
      }, { "jobs:open": { title: "Jobs", description: "see or stop background jobs", slash: "jobs" } });
    });
  },
};
