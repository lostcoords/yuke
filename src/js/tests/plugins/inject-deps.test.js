import { check } from "yuke:test";
import { plugins, services } from "yuke:ext";

const log = [];
plugins.use({
  name: "two-deps",
  apply(ctx) {
    ctx.inject(["a", "b"], () => {
      log.push("on");
      return () => log.push("off");
    });
  },
});
const offA = services.provide("a", 1);
check("one-is-not-enough", log.length === 0);
services.provide("b", 2);
check("both", log.join(",") === "on");
offA();
check("lost-one", log.join(",") === "on,off");

// A disposed plugin drops its watchers, so a later provider must not revive the block.
plugins.dispose("two-deps");
services.provide("a", 3);
check("no-revival", log.join(",") === "on,off");

// A repeated name registers one watcher, so one change builds the block one time.
const seen = [];
plugins.use({ name: "dupe", apply: (ctx) => ctx.inject(["d", "d"], () => { seen.push("built"); }) });
services.provide("d", 1);
check("built-once", seen.length === 1);

// A provider of undefined still holds the name.
const offU = services.provide("u", undefined);
check("undefined-counts", services.has("u") && services.get("u") === undefined);
offU();
check("undefined-leaves", !services.has("u"));
