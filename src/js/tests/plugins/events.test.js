import { check } from "yuke:test";
import { events, root, Emitter } from "yuke:core";
import { Scope, Context } from "yuke:ext";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

// A throwing teardown reports on the bus and never stops the rest.
{
  const seen = [];
  const off = events.on("ext.error", (e, name) => seen.push(name));
  const s = new Scope("t3");
  s.effect(() => () => { throw new Error("boom"); });
  s.effect(() => () => seen.push("after"));
  s.dispose();
  off();
  check("dispose-isolate", seen.join(",") === "after,t3");
}

// emit runs every listener and isolates a throwing one.
{
  const em = new Emitter();
  em.onError = () => {};
  let hits = 0;
  em.on("x", () => { hits++; throw new Error("boom"); });
  em.on("x", () => { hits++; });
  em.emit("x");
  check("emit-isolate", hits === 2);
}

// bail stops at the first listener that claims the event.
{
  const em = new Emitter();
  const seen = [];
  em.on("k", () => { seen.push(1); });
  em.on("k", () => { seen.push(2); return "claimed"; });
  em.on("k", () => { seen.push(3); });
  check("bail", em.bail("k") === "claimed" && seen.join(",") === "1,2");
}

// Context.on subscribes on the shared bus and goes away with its scope.
{
  const s = new Scope("t5");
  const ctx = new Context(s, "p5");
  let got = 0;
  ctx.on("ui.tick", () => got++);
  events.emit("ui.tick", null);
  s.dispose();
  events.emit("ui.tick", null);
  check("ctx-on-dispose", got === 1);
}

// The core bus declares a core name, and leaves an `owner:event` name to its owner.
{
  check("bus-typo", throws(() => events.emit("ui.tik", null)));
  check("bus-typo-on", throws(() => events.on("sesion.changed", () => {})));
  check("bus-plugin-free", !throws(() => events.emit("myplugin:thing", 1)));
  check("bus-plugin-on-free", !throws(() => events.on("myplugin:thing", () => {})));
  check("bus-service-free", !throws(() => events.emit("service:anything", 1)));
  // A namespace needs both halves, so neither one alone opens the bus.
  check("bus-no-owner", throws(() => events.emit(":thing", 1)));
  check("bus-no-event", throws(() => events.emit("myplugin:", 1)));
}

// An inherited object name is not a declared event, and a namespace needs a real suffix.
{
  check("bus-inherited", throws(() => events.emit("toString", 1)));
  check("bus-inherited-on", throws(() => events.on("constructor", () => {})));
  check("bus-namespace-empty", throws(() => events.emit("service:", 1)));
}

// Every entry point validates, and every declared name is accepted.
{
  check("bus-once-typo", throws(() => events.once("ui.tik", () => {})));
  check("bus-bail-typo", throws(() => events.bail("ui.tik")));
  const core = ["ui.start", "ui.closed", "ui.resize", "ui.tick", "key.press", "mouse.input",
    "paste.input", "focus.changed", "clipboard.copied", "session.changed", "index.changed",
    "ext.error"];
  const bad = core.filter((n) => throws(() => events.on(n, () => {})()));
  check("bus-core-declared:" + bad.join("|"), bad.length === 0);
}

// A host event reaches the core name it maps to, and one throwing listener spares the rest.
{
  const seen = [];
  const offs = [
    events.on("key.press", () => { throw new Error("listener"); }),
    events.on("key.press", () => seen.push("key")),
    events.on("mouse.input", () => seen.push("mouse")),
    events.on("ui.tick", () => seen.push("tick")),
    events.on("focus.changed", () => seen.push("focus")),
    events.on("paste.input", () => seen.push("paste")),
    events.on("ui.resize", () => seen.push("resize")),
    events.on("ui.start", () => seen.push("start")),
  ];
  root.onEvent({ type: "start" });
  root.onEvent({ type: "resize", w: 80, h: 24 });
  root.onEvent({ type: "key", code: "char", char: "x", text: "", event: "press", mods: 0 });
  root.onEvent({ type: "mouse", col: 1, row: 1, button: "left", event: "press", mods: 0, count: 1 });
  root.onEvent({ type: "paste", text: "p" });
  root.onEvent({ type: "focus", focused: true });
  root.onEvent({ type: "tick" });
  check("root-event-names", JSON.stringify(seen) === JSON.stringify(["start", "resize", "key", "mouse", "paste", "focus", "tick"]));
  for (const f of offs) f();
}
