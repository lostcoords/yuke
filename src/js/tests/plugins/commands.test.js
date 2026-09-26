import { check } from "yuke:internal/test";
import { command } from "yuke:internal/core";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

// A later registration shadows an earlier one; its dispose uncovers what it hid.
{
  const seen = [];
  const offA = command.add("test:shadow", { run: () => seen.push("a") });
  const offB = command.add("test:shadow", { run: () => seen.push("b") });
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
  const offA = command.add("test:gate", { run: () => seen.push("base") });
  const offB = command.add("test:gate", { when: () => allow, run: () => seen.push("top") });
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
  const offA = command.add("test:twice", { run: () => {} });
  offA();
  const offB = command.add("test:twice", { run: () => {} });
  offA();
  check("command-dispose-twice", command.map["test:twice"].length === 1);
  offB();
}

// Every gate shape resolves: a bare boolean, [true], [true, x], and [false].
{
  const got = [];
  const off = [
    command.add("test:g1", { when: () => true, run: (...a) => got.push("g1:" + a.length) }),
    command.add("test:g2", { when: () => [true], run: (...a) => got.push("g2:" + a.length) }),
    command.add("test:g3", { when: () => [true, "x"], run: (...a) => got.push("g3:" + a[0]) }),
    command.add("test:g4", { when: () => [false], run: () => got.push("g4") }),
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
  const off = command.add("test:boom", { when: () => { throw new Error("gate"); }, run: () => {} });
  const listed = command.available("test:boom");
  const threw = throws(() => command.perform("test:boom"));
  check("command-gate-throw", listed && threw);
  off();
}

// `slash: true` answers the name after the owner prefix, a string names another word, and a command needs a run function.
{
  const offs = [
    command.add("test:hello", { desc: "d", slash: true, run: () => {} }),
    command.add("test:named", { desc: "d", slash: "other", run: () => {} }),
  ];
  const slashOf = (name) => command.list().find((c) => c.name === name)?.slash;
  let threw = false;
  try { command.add("test:norun", /** @type {any} */ ({ desc: "d" })); } catch (e) { threw = e instanceof TypeError; }
  check("slash-derivation", slashOf("test:hello") === "hello" && slashOf("test:named") === "other" && threw && !command.map["test:norun"]);
  // Only a listed command reaches the slash menu, so a slash word without `desc` is refused rather than never answered.
  check("slash-needs-desc", throws(() => command.add("test:hidden", /** @type {any} */ ({ slash: true, run: () => {} }))) && !command.map["test:hidden"]);
  for (const off of offs) off();
}
