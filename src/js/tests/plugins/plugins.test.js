import { check } from "yuke:test";
import { command } from "yuke:core";
import { plugins, rootScope } from "yuke:ext";
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

// A disposed plugin releases its root entry, so reloads do not retain one capture each.
{
  const held = rootScope._disposers.length;
  for (let i = 0; i < 32; i++) {
    plugins.use({ name: "short", apply() {} });
    plugins.dispose("short");
  }
  check("plugin-root-entry-released", rootScope._disposers.length === held);
}

// A second use of a live name disposes the first, so nothing stacks on reload.
{
  let disposals = 0;
  const p = { name: "dup", apply(ctx) { ctx.effect(() => () => disposals++); } };
  plugins.use(p);
  plugins.use(p);
  const once = disposals === 1;
  plugins.dispose("dup");
  check("plugin-reload-disposes", once && disposals === 2 && plugins.names().indexOf("dup") < 0);
}

// A throwing apply reverts what it already registered and leaves no live plugin.
{
  const bad = { name: "bad", apply(ctx) { const t = tui.bindTo(ctx); t.command(null, { act: () => {} }); throw new Error("nope"); } };
  let threw = false;
  try { plugins.use(bad); } catch (e) { threw = true; }
  check("plugin-partial-revert", threw && !command.map["bad:act"] && !plugins.get("bad"));
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
