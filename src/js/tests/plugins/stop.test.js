import { check, equal } from "yuke:test";
import { plugins } from "yuke";

let finish;
let calls = 0;
let disposed = 0;
let nested;
const off = plugins.use({
  name: "async-stop",
  apply(ctx) { ctx.effect(() => () => { disposed++; }); },
  stop(ctx) {
    calls++;
    equal(ctx.id, "async-stop");
    check("registrations leave before stop", !ctx.scope.alive);
    nested = plugins.dispose(ctx.id);
    return new Promise(resolve => { finish = resolve; });
  },
});
const first = off.dispose();
equal(first, nested);
equal(first, plugins.dispose("async-stop"));
equal(calls, 1);
equal(disposed, 1);
let refused = false;
try { plugins.use({ name: "async-stop", apply() {} }); } catch { refused = true; }
check("replacement waits for stop", refused);
finish();
globalThis.stopDone = false;
first.then(() => {
  equal(disposed, 1);
  equal(plugins.get("async-stop"), undefined);
  plugins.use({ name: "async-stop", apply() {} });
  off.dispose();
  check("old handle cannot stop replacement", plugins.get("async-stop"));
  plugins.dispose("async-stop");
  globalThis.stopDone = true;
});
