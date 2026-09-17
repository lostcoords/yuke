import { check, equal } from "yuke:test";
import { plugins, events } from "yuke";
import { services } from "yuke:ext";

const faults = [];
const unwatch = events.on("ext.error", (error, name) => faults.push(name + ":" + error.message));
globalThis.startDone = false;
(async () => {
  let resume;
  let context;
  let released = 0;
  let stops = 0;
  const handle = plugins.use({
    name: "pending",
    async apply(ctx) {
      context = ctx;
      ctx.provide("pending-service", 1);
      ctx.own(() => { released++; });
      await new Promise(resolve => { resume = resolve; });
      let refused = false;
      try { ctx.own(() => { released++; }); } catch { refused = true; }
      check("late resource is refused", refused);
      check("late resource is released", released === 1);
      try { ctx.provide("late-service", 1); } catch { return; }
      throw new Error("late registration survived");
    },
    stop(ctx) {
      stops++;
      check("cancel precedes stop", ctx.signal.aborted);
      check("stop sees partial startup", released === 0);
    },
  });
  const ready = handle.ready.catch(error => error.name);
  const closed = handle.dispose();
  equal(closed, handle.dispose());
  equal(closed, plugins.dispose("pending"));
  equal(stops, 1);
  check("registration is gone", !services.has("pending-service"));
  equal(await ready, "AbortError");
  check("name stays held while startup exits", plugins.get("pending"));
  resume();
  await closed;
  equal(released, 2);
  equal(plugins.get("pending"), undefined);
  check("signal stays aborted", context.signal.aborted);

  const next = plugins.use({ name: "pending", async apply(ctx) {
    await Promise.resolve();
    ctx.provide("started", 1);
  } });
  await next.ready;
  check("registration after await is live", services.has("started"));
  handle.dispose();
  check("old handle keeps replacement", plugins.get("pending"));
  await next.dispose();

  let partial = 0;
  const failed = plugins.use({ name: "failed", async apply(ctx) {
    ctx.own(() => { partial++; });
    await Promise.resolve();
    throw new Error("startup failed");
  }, stop() { partial++; } });
  equal(await failed.ready.catch(error => error.message), "startup failed");
  await failed.dispose();
  equal(partial, 2);
  equal(faults.join(","), "failed:startup failed");
  unwatch();
  globalThis.startDone = true;
})().catch(error => { globalThis.startFailure = String(error.stack); globalThis.startDone = true; });
