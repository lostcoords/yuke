import { check } from "yuke:test";
import { command, keymap } from "yuke:core";
import { Scope, Context, advice, services } from "yuke:ext";
import { tui } from "yuke:tui";

// advice folds before, around, filterReturn, and after, then restores on removal.
{
  const obj = { hits: [], greet(n) { this.hits.push("orig:" + n); return "hi " + n; } };
  const original = obj.greet;
  const offs = [
    advice.advise(obj, "greet", "before", function (n) { this.hits.push("before:" + n); }, { owner: "o", name: "b" }),
    advice.advise(obj, "greet", "after", function (n) { this.hits.push("after:" + n); }, { owner: "o", name: "a" }),
    advice.advise(obj, "greet", "around", function (orig, n) { return orig(n.toUpperCase()); }, { owner: "o", name: "ar" }),
    advice.advise(obj, "greet", "filterReturn", function (r) { return r + "!"; }, { owner: "o", name: "f" }),
  ];
  const out = obj.greet("bob");
  check("advice-compose", out === "hi BOB!" && obj.hits.join(",") === "before:bob,orig:BOB,after:bob");
  for (const off of offs) off();
  check("advice-restore", obj.greet === original);
}

// Advice with no `around` still folds the other kinds.
{
  const obj = { log: [], f(n) { this.log.push("orig:" + n); return n; } };
  const off = advice.advise(obj, "f", "filterReturn", (r) => r * 2, { owner: "o", name: "d" });
  check("advice-no-around", obj.f(3) === 6 && obj.log.join(",") === "orig:3");
  off();
}

// The same owner and name replaces in place rather than stacking.
{
  const obj = { log: [], f() { this.log.push("orig"); } };
  advice.advise(obj, "f", "before", function () { this.log.push("v1"); }, { owner: "o", name: "n" });
  const off2 = advice.advise(obj, "f", "before", function () { this.log.push("v2"); }, { owner: "o", name: "n" });
  const replaced = advice.list(obj, "f").length === 1;
  obj.f();
  off2();
  check("advice-replace", replaced && obj.log.join(",") === "v2,orig" && advice.list(obj, "f").length === 0);
}

// filterArgs rewrites the arguments that the original and `after` both see.
{
  const obj = { log: [], f(a, b) { this.log.push("orig:" + a + b); return a + b; } };
  const off = advice.advise(obj, "f", "filterArgs", (as) => [as[0] * 2, as[1] * 2], { owner: "o", name: "fa" });
  const seen = [];
  const off2 = advice.advise(obj, "f", "after", (a, b) => seen.push(a + "," + b), { owner: "o", name: "af" });
  const out = obj.f(1, 2);
  off(); off2();
  check("advice-filter-args", out === 6 && obj.log.join(",") === "orig:24" && seen.join(",") === "2,4");
}

// An accessor is not a method, so advise refuses it.
{
  const obj = { get g() { return () => 1; } };
  let threw = false;
  const want = "is an accessor";
  try { advice.advise(obj, "g", "before", () => {}); } catch (e) { threw = e instanceof TypeError && e.message.indexOf(want) >= 0; }
  check("advice-accessor", threw);
}

// A Context forces its own id as the advice owner and keeps a qualified name intact.
{
  const s = new Scope("t7");
  const ctx = new Context(s, "p7");
  const t = tui.bindTo(ctx);
  const obj = { f() { return 1; } };
  ctx.advise(obj, "f", "filterReturn", (r) => r + 1, { name: "inc" });
  const owned = advice.list(obj, "f")[0];
  t.command(null, { bare: () => {}, "other:kept": () => {} });
  t.keymap({ "ctrl+y": "p7:bare" });
  ctx.provide("svc7", 42);
  const ok = owned.owner === "p7" && obj.f() === 2 &&
    !!command.map["p7:bare"] && !!command.map["other:kept"] &&
    !!keymap.map["ctrl+y"] && services.get("svc7") === 42;
  s.dispose();
  const gone = !command.map["p7:bare"] && !command.map["other:kept"] &&
    !keymap.map["ctrl+y"] && services.get("svc7") === undefined &&
    obj.f() === 1 && advice.list(obj, "f").length === 0;
  check("context-surface", ok && gone);
}
