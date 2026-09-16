import { exec } from "yuke:exec";
import { spawn as spawnNative } from "yuke:process";
import { spawn as spawnWith, lines } from "yuke:spawn";
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

  // A write to a child that closed its input rejects, because SIGPIPE is ignored.
  const deaf = spawn(["sh", "-c", "exec 0<&-; echo ready; sleep 2"]);
  let said = "";
  deaf.onStdout((text) => { said += text; });
  await until(() => said.includes("ready"));
  let epipe = "";
  try { await deaf.write("x".repeat(200000)); } catch (e) { epipe = e.message; }
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

  // A character that a read cuts in two arrives whole.
  const split = spawn(["sh", "-c", "printf '\\346'; sleep 0.1; printf '\\227\\245'"]);
  let text = "";
  split.onStdout((chunk) => { text += chunk; });
  await split.exited;
  check("split-char", text === "日");

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

  // A string runs through the host shell, and a logged child writes both streams to its log.
  const logged = spawnNative("echo out; echo bad 1>&2", { log: true }, undefined, "/tmp");
  check("logged-exit", (await logged.exited).code === 0);
  check("logged-content", (await exec(`cat '${logged.log}'`)).stdout === "out\nbad\n[exited with code 0]\n");

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
