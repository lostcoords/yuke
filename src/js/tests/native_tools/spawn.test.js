import { exec } from "yuke:exec";
import { spawn as spawnNative } from "yuke:process";
import { spawn as spawnWith, lines } from "yuke:spawn";
import { start as startJob, jobs } from "yuke:jobs";
import { events } from "yuke:kernel";
// The test host has no PATH, so every child names the utility directories.
const env = { PATH: "/usr/bin:/bin" };
const spawn = (argv, options = {}) => spawnWith(argv, { ...options, env: { ...env, ...(options.env ?? {}) } });
const until = async (ready) => { for (let i = 0; i < 1000 && !ready(); i++) await new Promise((resolve) => setTimeout(resolve, 5)); };
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
globalThis.result = "pending";
globalThis.fixtureDir = globalThis.fixtureDir ?? "";
(async () => {
  // Writes arrive in order, and every chunk reaches its listener before `exited` resolves.
  const cat = spawn(["cat"]);
  let echoed = "";
  cat.onStdout((text) => { echoed += text; });
  await cat.write("one\n");
  await cat.write("two\n");
  cat.closeStdin();
  const catExit = await cat.exited;
  check("cat-order", echoed === "one\ntwo\n" && catExit.code === 0 && catExit.signal === null);

  const blocked = spawn(["/bin/sh", "-c", "sleep 30"]);
  const queued = blocked.write("x".repeat(1024).repeat(1024)).catch(() => {});
  let full = false;
  try { await blocked.write("x"); } catch (e) { full = e.message.includes("queue is full"); }
  check("stdin-byte-limit", full);
  check("stop-accepted", blocked.kill());
  blocked.kill();
  await blocked.exited;
  await queued;

  // A write to a child that closed its input rejects, because SIGPIPE is ignored.
  const deaf = spawn(["sh", "-c", "exec 0<&-; echo ready; sleep 2"]);
  let said = "";
  deaf.onStdout((text) => { said += text; });
  await until(() => said.includes("ready"));
  let epipe = "";
  try { await deaf.write("x".repeat(1000).repeat(200)); } catch (e) { epipe = e.message; }
  check("write-epipe", epipe === "the process closed its input");
  deaf.kill();
  await deaf.exited;

  // A kill ends the whole group, and the exit names the signal number.
  const tree = spawn(["sh", "-c", "sleep 60 & echo $!; wait"]);
  let grandchild = "";
  tree.onStdout((text) => { grandchild += text; });
  await until(() => grandchild.includes("\n"));
  check("kill-running", tree.kill() === true);
  const treeExit = await tree.exited;
  check("signal-exit", treeExit.code === null && treeExit.signal === 15);
  check("grandchild-gone", Number(grandchild) > 0 && (await exec(`kill -0 ${Number(grandchild)} 2>/dev/null`)).code !== 0);
  check("kill-exited", tree.kill() === false);

  const streams = spawn(["sh", "-c", "echo out; echo bad 1>&2; exit 4"]);
  let out = "", bad = "";
  streams.onStdout((chunk) => { out += chunk; });
  streams.onStderr((chunk) => { bad += chunk; });
  check("streams", (await streams.exited).code === 4 && out === "out\n" && bad === "bad\n");

  let reason = "";
  try { await spawn(["yuke-no-such-program"]).exited; } catch (e) { reason = e.message; }
  check("missing-program", reason === "the program does not exist");

  // A bare name resolves against the PATH the child receives, not the PATH of this process.
  if (globalThis.fixtureDir !== "") {
    const fixture = spawn(["yuke-fixture-hello"], { env: { PATH: globalThis.fixtureDir } });
    let hello = "";
    fixture.onStdout((chunk) => { hello += chunk; });
    check("path-from-env", (await fixture.exited).code === 0 && hello === "fixture\n");
  }

  // The job table emits a fresh copy of each change, a stop of an exited job keeps its real end, and the log ends with the exit line.
  const changes = [];
  const off = events.on("jobs.changed", (job) => { changes.push(`${job.id} ${job.state}`); job.state = "mutated"; });
  let uppercase = "";
  try { await startJob("true", { root: "/tmp", sessionId: "AA" + "00".repeat(15) }); } catch (e) { uppercase = e.message; }
  check("uppercase-session-rejects", uppercase === "the session id must be 32 lowercase hex digits");
  const long = await startJob("sleep 30", { root: "/tmp", sessionId: "01010101010101010101010101010101" });
  const quick = await startJob("echo out; echo bad 1>&2; echo \"$PYTHONUNBUFFERED\"; exit 3", { root: "/tmp" });
  await until(() => jobs.get(quick.id)?.state === "exited");
  check("job-exit", jobs.get(quick.id)?.exit_code === 3 && (await jobs.stop(quick.id))?.state === "exited");
  const log = await jobs.read(quick.id, 0, 4096);
  // The host builds the answer object directly, so its keys and numbers must match the public shape exactly.
  check("job-log", JSON.stringify(log) === JSON.stringify({ start: 0, complete: true, text: "out\nbad\n1\n", next: 10, size: 10 }));
  check("job-stop", (await jobs.stop(long.id))?.stop_requested && (await jobs.wait(long.id))?.state === "exited" && jobs.list().some((j) => j.id === long.id && j.session_id === "01010101010101010101010101010101" && j.cwd === "/tmp"));
  check("job-events", changes.join(",") === `${long.id} running,${quick.id} running,${quick.id} exited,${long.id} running,${long.id} exited`);
  check("job-public", !("start" in jobs) && jobs.get(999) === null && jobs.list()[0]?.id === quick.id && jobs.list().every((j) => j.state !== "mutated"));
  off();

  const refusals = [
    () => spawn([]),
    () => spawn(["echo", "ok\0cut"]),
    () => spawn(["true"], { env: { "BAD=KEY": "x" } }),
    () => spawnNative(["true"], {}, () => {}, "relative"),
    () => spawnNative(["true"], {}),
  ];
  check("refusals", refusals.every((call) => { try { call(); return false; } catch (e) { return e.name === "TypeError"; } }));

  // `lines` holds a partial line and strips one CR.
  const got = [];
  const feed = lines((line) => got.push(line));
  feed("a\r\nb");
  feed("c\n\nd");
  check("lines", got.join("|") === "a|bc|");

  globalThis.result = fail.length ? fail.join(",") : "ok";
})().catch((e) => { globalThis.result = "threw: " + e.message; });
