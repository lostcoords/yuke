import { check, equal } from "yuke:test";
import { plugins } from "yuke";

let finish;
let releases = 0;
let disposed = 0;
let nested;
const off = plugins.use({
  name: "async-release",
  apply(ctx) {
    ctx.effect(() => () => { disposed++; });
    ctx.own(() => {
      releases++;
      check("registrations leave before the release", !ctx.alive);
      nested = plugins.dispose(ctx.id);
      return new Promise(resolve => { finish = resolve; });
    });
  },
});
const first = off.dispose();
equal(first, nested);
equal(first, plugins.dispose("async-release"));
equal(releases, 1);
equal(disposed, 1);
let refused = false;
try { plugins.use({ name: "async-release", apply() {} }); } catch { refused = true; }
check("replacement waits for the release", refused);
finish();
globalThis.stopDone = false;
first.then(() => {
  equal(disposed, 1);
  equal(plugins.has("async-release"), false);
  plugins.use({ name: "async-release", apply() {} });
  off.dispose();
  check("old handle cannot close replacement", plugins.has("async-release"));
  plugins.dispose("async-release");
  globalThis.stopDone = true;
});
