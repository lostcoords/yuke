import { root, status } from "yuke:core";
import { plugins } from "yuke:ext";
import { tuiPlugin } from "yuke:tui";
import { notice } from "yuke:notice";
import { jobsUiPlugin, openJobs, openOutput, JobOutput } from "yuke:jobs-ui";
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
  await until(() => jobs.get(two.id)?.state === "exited");
  check("x-stops-selected", jobs.get(quick.id)?.state === "exited" && jobs.get(one.id)?.state === "running");
  check("list-refreshes", picker.win.opts.title === "Jobs · 1 running · 2 ended");

  key(picker, "X");
  await until(() => jobs.get(one.id)?.state === "exited");
  await until(() => notice.text.includes("stop requested"));
  check("X-stops-all", notice.text === "jobs · stop requested for 1" && !status.side("right").includes("jobs"));

  picker.content.onKey({ type: "key", code: "esc", event: "press", mods: 0 });
  check("esc-closes", root.overlays.length === 0);

  // The output view follows a growing log, keeps the unfinished last line, and ends with the exit line.
  const texts = (view) => view.pager.source.rows(200, 0, 100000).map((r) => r.text);
  const talky = await start("for i in 1 2 3; do echo line$i; sleep 0.05; done; printf 'tail'", { root: "/tmp" });
  // Enter in the list opens the output view of the selected job.
  const list = openJobs(tui);
  list.content.selectKey(talky.id);
  list.content.onKey({ type: "key", code: "enter", event: "press", mods: 0 });
  const view = root.overlays.at(-1)?.content;
  check("enter-opens-output", root.overlays.length === 1 && view instanceof JobOutput && view.job.id === talky.id);
  for (let i = 0; i < 60 && !texts(view).includes("[exit code 0]"); i++) { view.tick(); await new Promise((resolve) => setTimeout(resolve, 50)); }
  check("output-follows", texts(view).join("|") === "line1|line2|line3|tail|[exit code 0]");
  view.onKey({ type: "key", code: "esc", event: "press", mods: 0 });
  check("output-closes", root.overlays.length === 0);

  // A long log opens at a whole line near its end, and `x` stops the job from the view.
  const long = await start("head -c 396000 /dev/zero | tr '\\0' a | fold -w 99; echo; echo last; sleep 30", { root: "/tmp" });
  for (let i = 0; i < 60 && (await jobs.read(long.id, Number.MAX_SAFE_INTEGER, 4)).size < 400005; i++) await new Promise((resolve) => setTimeout(resolve, 50));
  const tailView = openOutput(tui, long);
  for (let i = 0; i < 60 && !texts(tailView).includes("last"); i++) { tailView.tick(); await new Promise((resolve) => setTimeout(resolve, 50)); }
  const shown = texts(tailView);
    check("output-starts-whole", shown.length > 1000 && shown.length < 4000 && shown.slice(0, -1).every((line) => line.length === 99) && shown.at(-1) === "last");
  tailView.onKey({ type: "key", code: "char", char: "x", text: "x", event: "press", mods: 0 });
  await until(() => jobs.get(long.id)?.state === "exited");
  check("output-x-stops", jobs.get(long.id)?.state === "exited");
  for (let i = 0; i < 20 && !texts(tailView).includes("[stopped]"); i++) await new Promise((resolve) => setTimeout(resolve, 50));
  check("output-shows-stop-line", texts(tailView).at(-1) === "[stopped]");
  tailView.onKey({ type: "key", code: "esc", event: "press", mods: 0 });

  // A first read inside a line waits for its newline; escapes go; an endless line is cut.
  const lines = new JobOutput(long, () => {});
  lines.partial = null;
  lines.append("inside a line");
  lines.append(" still\n\x1b[31mred\x1b[0m\tend\n" + "x".repeat(5000));
  check("output-lines", texts(lines).join("|") === "red    end|" + "x".repeat(4096));

  const whole = new JobOutput(long, () => {});
  const split = new JobOutput(long, () => {});
  const huge = "z".repeat(20000) + "\nend\n";
  whole.append(huge);
  for (let i = 0; i < huge.length; i += 997) split.append(huge.slice(i, i + 997));
  check("line-cap-independent-of-chunks", texts(whole).join("|") === "z".repeat(4096) + "|end" && texts(split).join("|") === texts(whole).join("|"));
  whole.append(Array.from({ length: 6000 }, (_, i) => `line${i}\n`).join(""));
  check("row-cap", texts(whole).length === 5000 && texts(whole)[0] === "line1000" && texts(whole).at(-1) === "line5999");

  const refusals = await Promise.all([jobs.read(long.id, -1, 4), jobs.read(long.id, 0, 262145), jobs.read(999, 0, 4)].map((p) => p.then(() => "", (e) => e.message)));
  check("read-refusals", refusals.join("|") === "read needs a byte offset and a byte count from 4 to 262144|read needs a byte offset and a byte count from 4 to 262144|the job does not exist");

  plugins.dispose("jobs-ui");
  await start("sleep 30", { root: "/tmp" });
  check("unload-drops-segment", !status.side("right").includes("jobs"));
  globalThis.result = fail.length ? fail.join(",") : "ok";
})().catch((e) => { globalThis.result = "threw: " + (e.stack || e.message); });
