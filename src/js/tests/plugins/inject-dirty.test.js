import { check } from "yuke:test";
import { events } from "yuke:kernel";
import { plugins, services } from "yuke:ext";

// The block replaces its own provider while it builds, so the first bound value goes stale.
const log = [];
services.provide("x", "old");
plugins.use({ name: "selfrep", apply: (ctx) => ctx.inject(["x"], (c) => {
  log.push(c.x);
  if (c.x === "old") services.provide("x", "new");
}) });
check("rebuilt-with-live-value", log.join(",") === "old,new");
check("registry-agrees", services.get("x") === "new");

// A block that never settles reports one fault and stops, so the build cannot spin.
const faults = [];
events.on("ext.error", (e, who) => faults.push(String(who)));
let n = 0;
services.provide("y", 0);
plugins.use({ name: "churn", apply: (ctx) => ctx.inject(["y"], () => { services.provide("y", ++n); }) });
check("stopped", faults.indexOf("churn") >= 0);
check("bounded", n <= 16);
