import { check } from "yuke:test";
import { events } from "yuke:core";
import { plugins, services } from "yuke:ext";

// Record whether each announced value matched the registry at the moment it arrived.
const agreed = [];
events.on("service:z", (v) => agreed.push(v === services.get("z")));

// This watcher replaces the provider while the first change still runs.
plugins.use({
  name: "chain",
  apply: (ctx) => ctx.inject(["z"], () => {
    if (services.get("z") === "B") services.provide("z", "C");
  }),
});
services.provide("z", "B");

check("saw-both", agreed.length === 2);
check("never-stale", agreed.every((ok) => ok));
check("live-is-c", services.get("z") === "C");
