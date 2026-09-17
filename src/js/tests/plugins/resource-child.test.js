import { check, equal } from "yuke:test";
import { plugins } from "yuke";
import { services } from "yuke:ext";

let child;
let released = 0;
const withdraw = services.provide("resource", 1);
const handle = plugins.use({ name: "resource-child", apply(ctx) {
  ctx.inject(["resource"], nested => {
    child = nested;
    nested.own(() => { released++; });
  });
} });
const signal = child.signal;
withdraw();
check("withdrawal cancels the child", signal.aborted);
equal(released, 1);
let refused = false;
try { child.own(() => { released++; }); } catch { refused = true; }
check("withdrawn child refuses a late resource", refused);
equal(released, 2);
globalThis.childDone = false;
Promise.resolve(handle.dispose()).then(() => { globalThis.childDone = true; });
