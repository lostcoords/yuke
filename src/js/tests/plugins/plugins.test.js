import { check } from "yuke:internal/test";
import { command } from "yuke:internal/core";
import { scopeOf, plugins } from "yuke:internal/ext";
import { tui } from "yuke:internal/tui";

// A plugin registers on use, reverts on dispose, and comes back on reload.
{
  const p = { name: "demo9", apply(ctx) { const t = tui.bindTo(ctx); t.command.add("act", { run: () => {} }); } };
  plugins.use(p);
  const present = !!command.map["demo9:act"];
  plugins.dispose("demo9");
  const gone = !command.map["demo9:act"];
  plugins.use(p);
  const back = !!command.map["demo9:act"];
  plugins.dispose("demo9");
  check("plugin-lifecycle", present && gone && back);
}

// A second use of a live name throws and leaves the first plugin live.
{
  let disposals = 0;
  const p = { name: "dup", apply(ctx) { ctx.effect(() => () => disposals++); } };
  plugins.use(p);
  let threw = false;
  try { plugins.use(p); } catch (e) { threw = e instanceof TypeError; }
  const kept = disposals === 0 && plugins.has("dup");
  plugins.dispose("dup");
  check("plugin-duplicate-rejected", threw && kept && disposals === 1 && plugins.names().indexOf("dup") < 0);
}

// A throwing apply reverts what it already registered and leaves no live plugin.
{
  const bad = { name: "bad", apply(ctx) { const t = tui.bindTo(ctx); t.command.add("act", { run: () => {} }); throw new Error("nope"); } };
  let threw = false;
  try { plugins.use(bad); } catch (e) { threw = true; }
  check("plugin-partial-revert", threw && !command.map["bad:act"] && !plugins.has("bad"));
}

// A plugin is `{ name, apply }` and nothing else, so no shape can register under a guessed name.
{
  const rejects = (p) => { try { plugins.use(p); return false; } catch (e) { return e instanceof TypeError; } };
  const fn = (ctx) => { tui.bindTo(ctx).command.add("act", { run: () => {} }); };
  fn.pluginName = "sneaky";
  check("plugin-rejects-function", rejects(fn));
  // This one survives a misapplied call, so only the shape test can turn it away.
  const quiet = () => {};
  check("plugin-rejects-quiet-function", rejects(quiet) && plugins.names().indexOf("quiet") < 0);
  check("plugin-function-registers-nothing", plugins.names().indexOf("sneaky") < 0 && plugins.names().indexOf("fn") < 0 && !command.map["fn:act"]);
  check("plugin-rejects-nameless", rejects({ apply(ctx) {} }));
  check("plugin-rejects-empty-name", rejects({ name: "", apply(ctx) {} }));
  check("plugin-rejects-no-apply", rejects({ name: "x" }));
}

// The registry key does not depend on a mutable context namespace.
{
  const handle = plugins.use({ name: "stable-key", apply(ctx) { ctx.id = "changed"; } });
  handle.dispose();
  check("registry-key-is-stable", !plugins.has("stable-key"));
}

// The plugin holds a context and the caller holds a handle, so neither can close or register through the other.
{
  let ctx;
  const handle = plugins.use({ name: "split-handle", apply(c) { ctx = c; } });
  check("handle-is-not-context", handle !== ctx && !("effect" in handle));
  check("context-cannot-close", !("scope" in ctx) && !("dispose" in ctx) && ctx.alive);
  handle.dispose();
  check("context-sees-close", !ctx.alive);
}

// A returned cleanup is the newest effect of apply, so it reverts first; a dispose inside apply runs it at once.
{
  const log = [];
  plugins.use({ name: "ret", apply(ctx) { ctx.effect(() => () => log.push("effect")); return () => log.push("cleanup"); } });
  plugins.dispose("ret");
  plugins.use({ name: "ret-closed", apply() { plugins.dispose("ret-closed"); return () => log.push("late"); } });
  check("plugin-returned-cleanup", log.join() === "cleanup,effect,late");
}

// A child plugin is a resource of its parent: the parent's close closes it and frees its name; a use after the close closes it at once.
{
  const log = [];
  const child = { name: "kid", apply(ctx) { ctx.effect(() => () => log.push("kid")); } };
  /** @type {import("yuke").Context | null} */
  let held = null;
  plugins.use({ name: "parent", apply(ctx) { held = ctx; ctx.use(child); ctx.effect(() => () => log.push("parent")); } });
  const live = plugins.has("kid");
  plugins.dispose("parent");
  let threw = false;
  try { held.use({ name: "late", apply(ctx) { ctx.effect(() => () => log.push("late")); } }); } catch (e) { threw = e instanceof TypeError; }
  check("plugin-use-owns-child", live && log.join() === "parent,kid,late" && threw && !plugins.has("kid") && !plugins.has("late"));
}

// A child that closes by any path leaves its parent, so a parent that starts and stops a child holds nothing per cycle.
{
  /** @type {import("yuke").Context | null} */
  let held = null;
  plugins.use({ name: "holder", apply(ctx) { held = ctx; } });
  const child = { name: "cycled", apply() {} };
  const owned = () => scopeOf(/** @type {any} */ (held))._life?.releases?.length ?? 0;
  for (let i = 0; i < 3; i++) held.use(child).dispose();
  const afterHandle = owned();
  for (let i = 0; i < 3; i++) { held.use(child); plugins.dispose("cycled"); }
  const afterRegistry = owned();
  held.use(child);
  const running = owned();
  plugins.dispose("holder");
  check("closed-child-leaves-parent", afterHandle === 0 && afterRegistry === 0 && running === 1 && !plugins.has("cycled"));
}
