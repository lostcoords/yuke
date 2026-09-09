import { check } from "yuke:test";
import { style } from "yuke:core";
import { plugins } from "yuke:ext";
import { tui } from "yuke:tui";

// style.add seeds only an absent name, invalidates a cached miss, and reverts on dispose.
{
  const missed = style.resolve("TestSeed").bold === undefined;
  const off = style.add({ TestSeed: { fg: "fg", bold: true }, Normal: { fg: "danger" } });
  const seeded = style.resolve("TestSeed").bold === true;
  const kept = style.groups.Normal.fg === "fg";
  off();
  const reverted = !("TestSeed" in style.groups) && style.resolve("TestSeed").bold === undefined;
  check("style-add", missed && seeded && kept && reverted && style.groups.Normal.fg === "fg");
}

// A plugin's highlight groups unload with the plugin.
{
  const stop = plugins.use({ name: "theme", apply: (c) => { tui.bindTo(c).style({ PluginGroup: { fg: "fg", bold: true } }); } });
  const on = style.resolve("PluginGroup").bold === true;
  stop();
  check("style-plugin", on && !("PluginGroup" in style.groups) && style.resolve("PluginGroup").bold === undefined);
}

// Two plugins want one group name: the first owns it and an unload cannot strip the second.
{
  const first = { fg: "fg", bold: true };
  const stopA = plugins.use({ name: "thA", apply: (c) => { tui.bindTo(c).style({ Shared: first }); } });
  const stopB = plugins.use({ name: "thB", apply: (c) => { tui.bindTo(c).style({ Shared: { fg: "danger" } }); } });
  stopA();
  check("style-collision", style.groups.Shared === first && style.resolve("Shared").bold === true);
  stopB();
  check("style-collision-clean", !("Shared" in style.groups));
}

// An inherited property name is not an existing group.
{
  const off = style.add({ toString: { fg: "danger", bold: true } });
  const seeded = style.resolve("toString").bold === true;
  off();
  check("style-own-property", seeded && !("toString" in style.groups) && style.groups.Normal.fg === "fg");
}

// A disposer runs once, so a repeat call cannot strip a live holder.
{
  const offA = style.add({ Held: { fg: "fg", bold: true } });
  const offB = style.add({ Held: { fg: "danger" } });
  offA();
  offA();
  check("style-dispose-once", style.resolve("Held").bold === true);
  offB();
  check("style-dispose-last", !("Held" in style.groups));
}
