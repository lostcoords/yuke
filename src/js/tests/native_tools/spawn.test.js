import { exec } from "yuke:exec";
import { spawn as spawnWith, lines } from "yuke:spawn";
// The test host has no PATH, so every child names the utility directories.
const spawn = (argv, options = {}) => spawnWith(argv, { ...options, env: { PATH: "/usr/bin:/bin", ...(options.env ?? {}) } });
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
  check("cat-order", echoed === "one\ntwo\n");
  check("cat-exit", catExit.code === 0 && catExit.signal === null);
  let late = "";
  try { await cat.write("x"); } catch (e) { late = e.message; }
  check("write-after-exit", late === "the process does not exist" || late === "the process input is closed");

  // A child that closed its input makes a write reject; SIGPIPE is ignored, so the host survives.
  const deaf = spawn(["sh", "-c", "exec 0<&-; sleep 2"]);
  await new Promise((resolve) => setTimeout(resolve, 100));
  let epipe = "";
  try { await deaf.write("x".repeat(200000)); } catch (e) { epipe = e.message; }
  check("write-epipe", epipe === "the process closed its input");
  deaf.kill();
  await deaf.exited;

  // A signal exit names the signal, and a kill reaches a grandchild.
  const tree = spawn(["sh", "-c", "sleep 60 & echo $!; wait"]);
  let grandchild = "";
  tree.onStdout((text) => { grandchild += text; });
  for (let i = 0; i < 500 && !grandchild.includes("\n"); i++) await new Promise((resolve) => setTimeout(resolve, 5));
  tree.kill();
  const treeExit = await tree.exited;
  check("signal-exit", treeExit.code === null && treeExit.signal === "SIGTERM");
  check("grandchild-gone", (await exec(`kill -0 ${grandchild.trim()} 2>/dev/null`)).code !== 0);

  // A character that a read cuts in two arrives whole.
  const split = spawn(["sh", "-c", "printf '\\346'; sleep 0.1; printf '\\227\\245'"]);
  let chunks = [];
  split.onStdout((text) => { chunks.push(text); });
  await split.exited;
  check("split-char", chunks.join("") === "日" && !chunks.join("").includes("�"));

  // stderr is its own stream.
  const err = spawn(["sh", "-c", "echo out; echo bad 1>&2; exit 4"]);
  let out = "", bad = "";
  err.onStdout((text) => { out += text; });
  err.onStderr((text) => { bad += text; });
  const errExit = await err.exited;
  check("streams", out === "out\n" && bad === "bad\n" && errExit.code === 4);

  // A missing program rejects `exited` and calls no listener.
  const missing = spawn(["yuke-no-such-program"]);
  let heard = false;
  missing.onStdout(() => { heard = true; });
  let reason = "";
  try { await missing.exited; } catch (e) { reason = e.message; }
  check("missing-program", reason === "the program does not exist" && !heard);

  // A bare name resolves against the PATH the child receives, not the PATH of this process.
  if (globalThis.fixtureDir !== "") {
    const fixture = spawn(["yuke-fixture-hello"], { env: { PATH: globalThis.fixtureDir } });
    let said = "";
    fixture.onStdout((text) => { said += text; });
    const fixtureExit = await fixture.exited;
    check("path-from-env", said === "fixture\n" && fixtureExit.code === 0);
  }

  // Argument errors throw.
  let thrown = "";
  try { spawn([]); } catch (e) { thrown = e.name; }
  check("empty-argv", thrown === "TypeError");

  // `lines` holds a partial line and strips one CR.
  const got = [];
  const feed = lines((line) => got.push(line));
  feed("a\r\nb");
  feed("c\n\nd");
  check("lines", got.join("|") === "a|bc|");

  globalThis.result = fail.length ? fail.join(",") : "ok";
})().catch((e) => { globalThis.result = "threw: " + e.message; });
