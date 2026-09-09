import { check } from "yuke:test";
import { plugins, services } from "yuke:ext";

// A block sees the capabilities it declared, and no other.
let saw = null;
services.provide("alpha", { tag: "A" });
services.provide("beta", { tag: "B" });
plugins.use({
  name: "reader",
  apply: (ctx) => ctx.inject(["alpha"], (c) => { saw = { alpha: c.alpha, beta: c.beta }; }),
});
check("bound-declared", saw && saw.alpha && saw.alpha.tag === "A");
check("undeclared-absent", saw && saw.beta === undefined);

// A replaced provider rebuilds the block, so the binding is never stale.
const seen = [];
plugins.use({ name: "watcher", apply: (ctx) => ctx.inject(["alpha"], (c) => { seen.push(c.alpha.tag); }) });
const off = services.provide("alpha", { tag: "A2" });
check("rebound", seen.join(",") === "A,A2");
off();
check("revealed", seen.join(",") === "A,A2,A");

// A capability must not shadow a context member, or the block would lose that method.
let refused = 0;
for (const bad of ["effect", "inject", "provide", "on", "scope", "id"]) {
  try { services.provide(bad, 1); } catch { refused += 1; }
}
check("provide-refuses-reserved", refused === 6);

let injectRefused = 0;
plugins.use({
  name: "reserved-dep",
  apply(ctx) {
    try { ctx.inject(["effect"], () => {}); } catch { injectRefused = 1; }
  },
});
check("inject-refuses-reserved", injectRefused === 1);

// `ctx.use` is gone, because a point-in-time read carries no lifetime.
let hasUse = 1;
plugins.use({ name: "no-use", apply(ctx) { hasUse = typeof ctx.use === "function" ? 1 : 0; } });
check("use-removed", hasUse === 0);
