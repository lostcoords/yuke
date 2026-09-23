import { check, equal } from "yuke:test";
import { plugins, services, Scope } from "yuke:ext";
import { events } from "yuke:kernel";
import * as cancellation from "yuke:cancellation-native";

globalThis.closeDone = false;
(async () => {
  // A cancel listener runs inside the close, so it can no longer own a resource there.
  {
    const scope = new Scope("listener");
    let refused = false;
    let released = 0;
    cancellation.listen(scope.signal, () => {
      try { scope.own(() => { released++; }); } catch { refused = true; }
    });
    await scope.dispose();
    check("listener-own-refused", refused && released === 1);
  }

  // A caller inside an async close waits for the same close.
  {
    const scope = new Scope("reentrant");
    let finish = () => {};
    /** @type {void | Promise<void>} */
    let inner;
    scope.own(() => new Promise((resolve) => { finish = resolve; }));
    scope.own(() => { inner = scope.dispose(); });
    const outer = scope.dispose();
    check("inner-waits", inner !== undefined && inner === outer);
    finish();
    await outer;
  }

  // An inject block is a child scope, so its signal is canceled before a newer parent effect reverts.
  {
    const withdraw = services.provide("close-order", 1);
    let blockSignal;
    let abortedAtRevert = false;
    const handle = plugins.use({ name: "close-order", apply(ctx) {
      ctx.inject(["close-order"], (block) => { blockSignal = block.signal; });
      ctx.effect(() => () => { abortedAtRevert = blockSignal.aborted; });
    } });
    await handle.dispose();
    withdraw();
    check("block-canceled-first", abortedAtRevert);
  }

  // A block that closes its own scope during apply is not kept as the live block.
  {
    const withdraw = services.provide("self-close", 1);
    let builds = 0;
    const handle = plugins.use({ name: "self-close", apply(ctx) {
      ctx.inject(["self-close"], (block) => { builds++; if (builds === 1) block.scope.dispose(); });
    } });
    const again = services.provide("self-close", 2);
    check("dead-block-not-live", builds === 2);
    again();
    withdraw();
    await handle.dispose();
  }

  // A child release that fails after the deadline stays silent.
  {
    let fail = (/** @type {Error} */ _error) => {};
    const faults = [];
    const off = events.on("ext.error", (error, owner) => faults.push(owner + ":" + error.message));
    const withdraw = services.provide("late-child", 1);
    const handle = plugins.use({ name: "late-child", apply(ctx) {
      ctx.inject(["late-child"], (block) => { block.own(() => new Promise((_resolve, reject) => { fail = reject; })); });
    } });
    await handle.dispose();
    equal(faults.join(","), "late-child:plugin close timed out");
    fail(new Error("late"));
    await Promise.resolve();
    await Promise.resolve();
    equal(faults.length, 1);
    off();
    withdraw();
  }
  globalThis.closeDone = true;
})().catch((error) => { globalThis.closeFailure = String(error.stack); globalThis.closeDone = true; });
