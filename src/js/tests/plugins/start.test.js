import { check, equal, until } from "yuke:internal/test";
import { plugins } from "yuke";
import { events } from "yuke:internal/kernel";
import { services } from "yuke:internal/ext";

const faults = [];
const unwatch = events.on("notify.posted", (n) => faults.push(n.source + ":" + n.message));
globalThis.startDone = false;
(async () => {
  let resume;
  let context;
  let released = 0;
  const late = { refused: false, released: 0, provideRefused: false };
  const handle = plugins.use({
    name: "pending",
    async apply(ctx) {
      context = ctx;
      ctx.provide("pending-service", 1);
      ctx.own(() => { released++; });
      await new Promise(resolve => { resume = resolve; });
      // A throw here is silent, because the plugin is closed, so the checks run outside.
      try { ctx.own(() => { released++; }); } catch { late.refused = true; }
      late.released = released;
      try { ctx.provide("late-service", 1); } catch { late.provideRefused = true; }
    },
  });
  const closed = handle.dispose();
  equal(closed, handle.dispose());
  equal(closed, plugins.dispose("pending"));
  check("cancel precedes the release", context.signal.aborted);
  equal(released, 1);
  check("registration is gone", !services.has("pending-service"));
  check("name stays held while the apply runs", plugins.has("pending"));
  resume();
  await closed;
  check("late resource is refused", late.refused);
  equal(late.released, 2);
  check("late registration is refused", late.provideRefused);
  equal(released, 2);
  equal(plugins.has("pending"), false);
  check("signal stays aborted", context.signal.aborted);

  const next = plugins.use({ name: "pending", async apply(ctx) {
    await Promise.resolve();
    ctx.provide("started", 1);
  } });
  await until(() => services.has("started"), "registration after await");
  handle.dispose();
  check("old handle keeps replacement", plugins.has("pending"));
  await next.dispose();

  // A close inside `apply` holds the name until the promise that `apply` returns settles.
  let resumeSelf = () => {};
  plugins.use({ name: "self-close", apply() {
    plugins.dispose("self-close");
    return new Promise((resolve) => { resumeSelf = resolve; });
  } });
  await Promise.resolve();
  check("self-close holds its name", plugins.has("self-close"));
  let replaced = true;
  try { plugins.use({ name: "self-close", apply() {} }); } catch { replaced = false; }
  check("self-close refuses a replacement", !replaced);
  resumeSelf();
  await until(() => !plugins.has("self-close"), "self-close release");

  let partial = 0;
  const failed = plugins.use({ name: "failed", async apply(ctx) {
    ctx.own(() => { partial++; });
    await Promise.resolve();
    throw new Error("startup failed");
  } });
  // The registry reports a failed apply and closes the plugin itself.
  await until(() => !plugins.has("failed"), "failed plugin close");
  await failed.dispose();
  equal(partial, 1);
  equal(faults.join(","), "failed:startup failed");
  unwatch();
  globalThis.startDone = true;
})().catch(error => { globalThis.startFailure = String(error.stack); globalThis.startDone = true; });
