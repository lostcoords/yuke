import { equal } from "yuke:test";
import { route } from "yuke:core";
globalThis.threw = 0;
for (const bad of ["view ", "KEYMAP", "", null, 1]) {
  try { route.add(bad); } catch (e) {
    if (e.message === "route.add: where must be keymap or view") globalThis.threw++;
  }
}
equal(String(globalThis.threw) + ":" + String(route.reader()), "5:view");
