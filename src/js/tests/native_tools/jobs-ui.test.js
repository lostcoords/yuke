import { root, status } from "yuke:core";
import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { notice } from "yuke:notice";
import { jobsUiPlugin, openJobs } from "yuke:jobs-ui";
import { start, jobs } from "yuke:jobs";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
const until = async (ready) => { for (let i = 0; i < 1000 && !ready(); i++) await new Promise((resolve) => setTimeout(resolve, 5)); };
const key = (picker, char) => picker.content.onKey({ type: "key", code: "char", char, text: char, event: "press", mods: 0 });
globalThis.result = "pending";
plugins.use(tuiPlugin);
plugins.use(jobsUiPlugin);
let tui = null;
plugins.use({ name: "jobs-ui-test", apply(ctx) { ctx.inject(["tui"], (ctx) => { tui = ctx; }); } });
(async () => {
  check("hidden-when-idle", !status.side("right").includes("jobs"));
  const one = await start("sleep 30", { root: "/tmp" });
  const two = await start("sleep 30", { root: "/tmp" });
  const quick = await start("exit 2", { root: "/tmp" });
  await until(() => jobs.get(quick.id)?.state === "exited");
  check("counts-running", status.side("right").includes("jobs 2"));

  // The list shows newest first, and `x` stops only the selected running job.
  const picker = openJobs(tui);
  check("rows-newest-first", picker.content.source.map((j) => j.id).join(",") === [quick.id, two.id, one.id].join(","));
  check("row-states", picker.win.opts.title === "Jobs · 2 running · 1 ended");
  key(picker, "x");
  picker.content.list.move(1);
  key(picker, "x");
  await until(() => jobs.get(two.id)?.state === "stopped");
  check("x-stops-selected", jobs.get(quick.id)?.state === "exited" && jobs.get(one.id)?.state === "running");
  check("list-refreshes", picker.win.opts.title === "Jobs · 1 running · 2 ended");

  key(picker, "X");
  await until(() => jobs.get(one.id)?.state === "stopped");
  await until(() => notice.text.includes("stopped"));
  check("X-stops-all", notice.text === "jobs · stopped 1" && !status.side("right").includes("jobs"));

  picker.content.onKey({ type: "key", code: "esc", event: "press", mods: 0 });
  check("esc-closes", root.overlays.length === 0);

  plugins.dispose("jobs-ui");
  await start("sleep 30", { root: "/tmp" });
  check("unload-drops-segment", !status.side("right").includes("jobs"));
  globalThis.result = fail.length ? fail.join(",") : "ok";
})().catch((e) => { globalThis.result = "threw: " + (e.stack || e.message); });
