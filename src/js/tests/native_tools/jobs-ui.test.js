import { root, status } from "yuke:core";
import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { notice } from "yuke:notice";
import { jobsUiPlugin, openJobs, openOutput } from "yuke:jobs-ui";
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

  // The output view follows a growing log, keeps the unfinished last line, and ends with the exit line.
  const texts = (view) => view.pager.source.rows(200, 0, 100000).map((r) => r.text);
  const talky = await start("for i in 1 2 3; do echo line$i; sleep 0.2; done; printf 'tail'", { root: "/tmp" });
  const view = openOutput(tui, talky);
  for (let i = 0; i < 60 && !texts(view).includes("[exited with code 0]"); i++) { view.tick(); await new Promise((resolve) => setTimeout(resolve, 50)); }
  check("output-follows", texts(view).join("|") === "line1|line2|line3|tail[exited with code 0]");
  view.onKey({ type: "key", code: "esc", event: "press", mods: 0 });
  check("output-closes", root.overlays.length === 0);

  // A long log opens at a whole line near its end, and `x` stops the job from the view.
  const long = await start("head -c 396000 /dev/zero | tr '\\0' a | fold -w 99; echo; echo last; sleep 30", { root: "/tmp" });
  const { fs } = await import("yuke:fs");
  let written = 0;
  await until(() => { fs.readFrom(long.log, Number.MAX_SAFE_INTEGER, 1).then((r) => { written = r.size; }); return written >= 400005; });
  const tailView = openOutput(tui, long);
  for (let i = 0; i < 60 && !texts(tailView).includes("last"); i++) { tailView.tick(); await new Promise((resolve) => setTimeout(resolve, 50)); }
  const shown = texts(tailView);
    check("output-starts-whole", shown.length > 1000 && shown.length < 4000 && shown.slice(0, -1).every((line) => line.length === 99) && shown.at(-1) === "last");
  tailView.onKey({ type: "key", code: "char", char: "x", text: "x", event: "press", mods: 0 });
  await until(() => jobs.get(long.id)?.state === "stopped");
  check("output-x-stops", jobs.get(long.id)?.state === "stopped");
  for (let i = 0; i < 20 && !texts(tailView).includes("[ended by signal 15]"); i++) await new Promise((resolve) => setTimeout(resolve, 50));
  check("output-shows-stop-line", texts(tailView).at(-1) === "[ended by signal 15]");
  tailView.onKey({ type: "key", code: "esc", event: "press", mods: 0 });

  plugins.dispose("jobs-ui");
  await start("sleep 30", { root: "/tmp" });
  check("unload-drops-segment", !status.side("right").includes("jobs"));
  globalThis.result = fail.length ? fail.join(",") : "ok";
})().catch((e) => { globalThis.result = "threw: " + (e.stack || e.message); });
