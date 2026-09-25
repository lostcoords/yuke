import { env } from "yuke";
import { check, equal } from "yuke:internal/test";

equal(env.get("YUKE_ENV_VALUE"), "hello 世界");
equal(env.get("YUKE_ENV_EMPTY"), "");
equal(env.get("YUKE_ENV_MISSING"), undefined);
equal(env.get("HOME"), "/effective/home");

let coerced = false;
for (const name of [undefined, null, 1, {}, { toString() { coerced = true; return "HOME"; } }, "", "HOME\0OTHER", "HOME=OTHER"]) {
  let rejected = false;
  try { env.get(name); } catch (error) { rejected = error instanceof TypeError; }
  check("invalid environment name", rejected);
}
check("environment names have no implicit conversion", !coerced);
equal(env.get("HOME"), "/effective/home");
