import { check, equal } from "yuke:test";
import { Refresh } from "yuke:refresh";

const pending = [];
let calls = 0, finishes = 0;
const refresh = new Refresh(
  () => { calls++; return new Promise((resolve, reject) => pending.push({ resolve, reject })); },
  () => ++finishes,
);
const first = refresh.run();
equal(refresh.run(), first);
equal(refresh.run(), first);
equal(calls, 1);
check("read-is-active", refresh.loading);
pending.shift().resolve();
for (let i = 0; i < 8; i++) await Promise.resolve();
equal(calls, 2);
equal(finishes, 1);
let done = false;
first.then(() => { done = true; });
for (let i = 0; i < 8; i++) await Promise.resolve();
check("callers-await-follow-up", !done && refresh.loading);
pending.shift().reject(new Error("read refused"));
equal(await first, 2);
check("refusal-ends-read", !refresh.loading);
const next = refresh.run();
equal(calls, 3);
pending.shift().resolve();
equal(await next, 3);
check("later-read-settles", !refresh.loading);
