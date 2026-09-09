import { check } from "yuke:test";
import { command } from "yuke:core";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

// A later registration shadows an earlier one; its dispose uncovers what it hid.
{
  const seen = [];
  const offA = command.add(null, { "test:shadow": () => seen.push("a") });
  const offB = command.add(null, { "test:shadow": () => seen.push("b") });
  command.perform("test:shadow");
  offB();
  command.perform("test:shadow");
  offA();
  const gone = !command.map["test:shadow"] && !command.perform("test:shadow");
  check("command-shadow", seen.join(",") === "b,a" && gone);
}

// A shadowing entry its gate rejects falls through to the entry below it.
{
  const seen = [];
  let allow = false;
  const offA = command.add(null, { "test:gate": () => seen.push("base") });
  const offB = command.add(() => allow, { "test:gate": () => seen.push("top") });
  const r1 = command.perform("test:gate");
  allow = true;
  const r2 = command.perform("test:gate");
  check("command-fallthrough", r1 && r2 && JSON.stringify(seen) === JSON.stringify(["base", "top"]));
  check("command-available", command.available("test:gate") && !command.available("test:absent"));
  allow = false;
  offA();
  check("command-unavailable", !command.available("test:gate"));
  offB();
}

// A disposer runs once; a second call leaves a later registration of the same name alone.
{
  const offA = command.add(null, { "test:twice": () => {} });
  offA();
  const offB = command.add(null, { "test:twice": () => {} });
  offA();
  check("command-dispose-twice", command.map["test:twice"].length === 1);
  offB();
}

// Every gate shape resolves: a bare boolean, [true], [true, x], and [false].
{
  const got = [];
  const off = [
    command.add(() => true, { "test:g1": (...a) => got.push("g1:" + a.length) }),
    command.add(() => [true], { "test:g2": (...a) => got.push("g2:" + a.length) }),
    command.add(() => [true, "x"], { "test:g3": (...a) => got.push("g3:" + a[0]) }),
    command.add(() => [false], { "test:g4": () => got.push("g4") }),
  ];
  command.perform("test:g1", 1);
  command.perform("test:g2", 1);
  command.perform("test:g3", 1);
  const ran4 = command.perform("test:g4", 1);
  check("command-gate-shapes", got.join(",") === "g1:1,g2:1,g3:x" && !ran4);
  for (const f of off) f();
}

// A throwing gate lists as available, and the throw still escapes perform.
{
  const off = command.add(() => { throw new Error("gate"); }, { "test:boom": () => {} });
  const listed = command.available("test:boom");
  const threw = throws(() => command.perform("test:boom"));
  check("command-gate-throw", listed && threw);
  off();
}
