import { check } from "yuke:test";
import { command } from "yuke:core";
import { plugins } from "yuke:ext";
import { tui } from "yuke:tui";

// A plugin registers on use, reverts on dispose, and comes back on reload.
{
  const p = { name: "demo9", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { act: () => {} }); } };
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
  const bad = { name: "bad", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { act: () => {} }); throw new Error("nope"); } };
  let threw = false;
  try { plugins.use(bad); } catch (e) { threw = true; }
  check("plugin-partial-revert", threw && !command.map["bad:act"] && !plugins.has("bad"));
}

// A plugin is `{ name, apply }` and nothing else, so no shape can register under a guessed name.
{
  const rejects = (p) => { try { plugins.use(p); return false; } catch (e) { return e instanceof TypeError; } };
  const fn = (ctx) => { tui.bindTo(ctx).command(null, { act: () => {} }); };
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
