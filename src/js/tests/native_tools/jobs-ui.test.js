import { root, status } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { notice } from "yuke:internal/notice";
import { jobsUiPlugin, openJobs, openOutput, JobOutput } from "yuke:internal/jobs-ui";
import { start, jobs } from "yuke:internal/jobs";
import { until } from "yuke:internal/test";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
const key = (picker, char) => picker.content.onKey({ type: "key", code: "char", char, text: char, event: "press", mods: 0 });
globalThis.result = "pending";
globalThis.talkyStage = 0;
globalThis.talkyId = 0;
plugins.use(tuiPlugin);
plugins.use(jobsUiPlugin);
let tui = null;
plugins.use({ name: "jobs-ui-test", apply(ctx) { ctx.inject(["tui"], (ctx) => { tui = ctx; }); } });
(async () => {
  check("hidden-when-idle", !status.side("right").includes("jobs"));
  const one = await start("sleep 30", { workspaceRoot: "/tmp" });
  const two = await start("sleep 30", { workspaceRoot: "/tmp" });
  const quick = await start("exit 2", { workspaceRoot: "/tmp" });
  await jobs.wait(quick.id);
  check("counts-running", status.side("right").includes("jobs 2"));

  // The list shows newest first, and `x` stops only the selected running job.
  const picker = openJobs(tui);
  check("rows-newest-first", picker.content.source.map((j) => j.id).join(",") === [quick.id, two.id, one.id].join(","));
  check("row-states", picker.win.opts.title === "Jobs · 2 running · 1 ended");
  key(picker, "x");
  picker.content.list.navBy(1);
  key(picker, "x");
  await jobs.wait(two.id);
  check("x-stops-selected", jobs.get(quick.id)?.state === "exited" && jobs.get(one.id)?.state === "running");
  check("list-refreshes", picker.win.opts.title === "Jobs · 1 running · 2 ended");

  key(picker, "X");
  await jobs.wait(one.id);
  check("X-stops-all", notice.text === "jobs · stop requested for 1" && !status.side("right").includes("jobs"));

  picker.content.onKey({ type: "key", code: "esc", event: "press", mods: 0 });
  check("esc-closes", root.overlays.length === 0);

  // The output view follows a growing log, keeps the unfinished last line, and ends with the exit line.
  const texts = (view) => view.pager.source.rows(200, 0, 100000).map((r) => r.text);
  const talky = await start(`sleep 30 & child=$!; stage=1
trap 'stage=$((stage + 1)); case "$stage" in
  2) printf "line2\\n" ;;
  3) printf "line3\\ntail" ;;
  4) kill "$child"; wait "$child" 2>/dev/null; exit 0 ;;
esac' USR1
printf 'line1\\n'
while :; do wait "$child"; done`, { workspaceRoot: "/tmp" });
  globalThis.talkyId = talky.id;
  // Enter in the list opens the output view of the selected job.
  const list = openJobs(tui);
  list.content.list.selectKey(talky.id);
  list.content.onKey({ type: "key", code: "enter", event: "press", mods: 0 });
  const view = root.overlays.at(-1)?.content;
  check("enter-opens-output", root.overlays.length === 1 && view instanceof JobOutput && view.job.id === talky.id);
  for (let stage = 1; stage <= 3; stage++) {
    const expected = ["line1", "line2", "line3"].slice(0, stage).join("|") + (stage === 3 ? "|tail" : "");
    const partial = stage === 3 ? "tail" : "";
    await until(async () => {
      await view.read();
      return texts(view).join("|") === expected && view.partial === partial;
    }, `output stage ${stage}`);
    check("output-stage-" + stage, texts(view).join("|") === expected && view.partial === partial);
    check("output-still-running-" + stage, jobs.get(talky.id)?.state === "running");
    globalThis.talkyStage = stage;
  }
  await jobs.wait(talky.id);
  await until(async () => { await view.read(); return texts(view).includes("[exit code 0]"); }, "output completion");
  check("output-follows", texts(view).join("|") === "line1|line2|line3|tail|[exit code 0]");
  view.onKey({ type: "key", code: "esc", event: "press", mods: 0 });
  check("output-closes", root.overlays.length === 0);

  // A long log opens at a whole line near its end, and `x` stops the job from the view.
  const long = await start("head -c 396000 /dev/zero | tr '\\0' a | fold -w 99; echo; echo last; sleep 30", { workspaceRoot: "/tmp" });
  await until(async () => (await jobs.read(long.id, Number.MAX_SAFE_INTEGER, 4)).size >= 400005, "long job output");
  const tailView = openOutput(tui, long);
  await until(async () => { await tailView.read(); return texts(tailView).includes("last"); }, "tail output");
  const shown = texts(tailView);
  check("output-starts-whole", shown.length > 1000 && shown.length < 4000 && shown.slice(0, -1).every((line) => line.length === 99) && shown.at(-1) === "last");
  tailView.onKey({ type: "key", code: "char", char: "x", text: "x", event: "press", mods: 0 });
  await jobs.wait(long.id);
  check("output-x-stops", jobs.get(long.id)?.state === "exited");
  await until(async () => { await tailView.read(); return texts(tailView).includes("[stopped]"); }, "stopped output");
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
  await start("sleep 30", { workspaceRoot: "/tmp" });
  check("unload-drops-segment", !status.side("right").includes("jobs"));
  globalThis.result = fail.length ? fail.join(",") : "ok";
})().catch((e) => { globalThis.result = "threw: " + (e.stack || e.message); });
