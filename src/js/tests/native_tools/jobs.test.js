import { exec, start, stop } from "yuke:exec";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
globalThis.result = "pending";
globalThis.closePid = 0;
(async () => {
  const quick = await start("echo hi; exit 3");
  check("id", typeof quick.id === "number" && quick.id > 0);
  check("log-path", quick.log.endsWith(".log"));
  const exit = await quick.exited;
  check("exit-code", exit.code === 3 && exit.signal === null);
  check("log-content", (await exec(`cat '${quick.log}'`)).stdout === "hi\n");
  check("stop-ended", (await stop(quick.id)) === false);

  const long = await start("sleep 30");
  check("stop-running", (await stop(long.id)) === true);
  const ended = await long.exited;
  check("stopped-exit", ended.code === null && ended.signal === 15);

  // The shell exits at once, and the host must end the process it left behind.
  const leaver = await start("sleep 30 >/dev/null 2>&1 & echo $!");
  await leaver.exited;
  const left = (await exec(`cat '${leaver.log}'`)).stdout.trim();
  check("leftover-ended", (await exec(`kill -0 ${left} 2>/dev/null`)).code !== 0);

  let message = "";
  try { await stop(0); } catch (e) { message = e.message; }
  check("stop-id-rejects", message === "the job id must be a positive whole number");
  message = "";
  try { await start("   "); } catch (e) { message = e.message; }
  check("blank-rejects", message === "the command must not be blank");

  // A job that still runs at host close must end with the host.
  const open = await start("echo $$; exec sleep 30");
  for (let i = 0; i < 200 && globalThis.closePid === 0; i++) {
    const text = (await exec(`cat '${open.log}'`)).stdout.trim();
    if (text.length !== 0) globalThis.closePid = Number(text);
  }
  globalThis.result = fail.length ? fail.join(",") : "ok";
})();
