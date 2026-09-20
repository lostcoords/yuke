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

// Each call adds one advice, so two anonymous advices from one plugin both run.
{
  const s = new Scope("stack");
  const ctx = new Context(s, "stack");
  const obj = { log: [], f() { this.log.push("orig"); } };
  const off = ctx.advise(obj, "f", "before", () => obj.log.push("before"));
  ctx.advise(obj, "f", "after", () => obj.log.push("after"));
  obj.f();
  const both = obj.log.join(",") === "before,orig,after";
  off();
  const one = advice.list(obj, "f").length === 1;
  s.dispose();
  check("advice-stack", both && one && advice.list(obj, "f").length === 0);
}

// A filterReturn advice that returns undefined keeps the result.
{
  const obj = { f() { return 1; } };
  const off = advice.advise(obj, "f", "filterReturn", () => {});
  check("advice-filter-return-undefined", obj.f() === 1);
  off();
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

// A stale handle cannot remove a later registration.
{
  const obj = { f() { return 1; } };
  const first = advice.advise(obj, "f", "filterReturn", () => 2);
  const second = advice.advise(obj, "f", "filterReturn", () => 3);
  first();
  check("advice-stale-handle", obj.f() === 3);
  second();
  const third = advice.advise(obj, "f", "filterReturn", () => 4);
  first(); second();
  check("advice-stale-reinstall", obj.f() === 4 && advice.list(obj).length === 1);
  third(); third();
  check("advice-repeat-dispose", obj.f() === 1 && advice.list(obj).length === 0);
}

// Disposal restores the own descriptor or exposes the prototype method again.
{
  const proto = { f() { return 1; } };
  const obj = Object.create(proto);
  const off = advice.advise(obj, "f", "filterReturn", () => 2);
  check("advice-inherited-call", obj.f() === 2);
  off();
  check("advice-inherited-restore", !Object.hasOwn(obj, "f"));
  proto.f = () => 3;
  check("advice-prototype-update", obj.f() === 3);
  Object.defineProperty(obj, "f", { value: () => 4, writable: true, configurable: false, enumerable: false });
  const original = Object.getOwnPropertyDescriptor(obj, "f");
  const ownOff = advice.advise(obj, "f", "filterReturn", () => 5);
  ownOff();
  const restored = Object.getOwnPropertyDescriptor(obj, "f");
  check("advice-own-descriptor", restored.value === original.value && restored.writable === original.writable && restored.configurable === original.configurable && restored.enumerable === original.enumerable);
}

// Object prototype names are not advice kinds.
for (const kind of ["toString", "constructor", "__proto__", "unknown"]) {
  const obj = { f() {} };
  const original = obj.f;
  let rejected = false;
  try { advice.advise(obj, "f", kind, () => {}); } catch (e) { rejected = e instanceof TypeError; }
  check("advice-kind-" + kind, rejected && obj.f === original && advice.list(obj).length === 0);
}

// The original call preserves argument iteration and its receiver without around advice.
{
  const obj = { bias: 10, f(a, b) { return this.bias + a + b; } };
  const args = [1, 2];
  args[Symbol.iterator] = function* () { yield 3; yield 4; };
  const off = advice.advise(obj, "f", "filterArgs", () => args);
  check("advice-argument-iterator", obj.f(0, 0) === 17);
  off();
}

// A before handler can change the around chain for the current call.
{
  const obj = { bias: 10, f(n) { return this.bias + n; } };
  let enabled = true, offAround = null;
  const offBefore = advice.advise(obj, "f", "before", () => {
    if (enabled && !offAround) offAround = advice.advise(obj, "f", "around", next => next(4) * 2);
    else if (!enabled && offAround) { offAround(); offAround = null; }
  });
  check("advice-add-around-during-call", obj.f(3) === 28);
  enabled = false;
  check("advice-remove-around-during-call", obj.f(3) === 13);
  offBefore();
}

// Retained next callbacks keep their call receiver after disposal.
{
  const saved = [];
  const obj = { name: "first", f() { return this.name; } };
  const off = advice.advise(obj, "f", "around", next => { saved.push(next); return next(); });
  obj.f();
  obj.f.call({ name: "second" });
  off();
  check("advice-retained-next", saved[0]() === "first" && saved[1]() === "second");
}

// Advice sees the promise itself and does not convert a synchronous throw into a rejection.
{
  const result = Promise.resolve(7);
  const failure = new Error("method failed");
  const obj = { f() { return result; }, fail() { throw failure; } };
  const scope = new Scope("promise-advice");
  const ctx = new Context(scope, "promise-advice");
  let after = 0, filtered;
  ctx.advise(obj, "f", "filterReturn", value => { filtered = value; });
  ctx.advise(obj, "f", "after", () => { after++; });
  ctx.advise(obj, "fail", "after", () => { after++; });
  check("advice-keeps-promise", obj.f() === result && filtered === result && after === 1);
  let caught;
  try { obj.fail(); } catch (error) { caught = error; }
  check("advice-keeps-throw", caught === failure && after === 1);
  scope.dispose();
}
