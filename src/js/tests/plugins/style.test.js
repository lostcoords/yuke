import { check } from "yuke:internal/test";
import { style } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { tui } from "yuke:internal/tui";

// The default palette depends on the terminal, so each check compares with its danger color.
const baseDanger = style.palette.danger;

// A set wins over the default in either order, and its dispose restores the default.
{
  const setFirst = style.set({ Layered: { fg: "danger" } });
  const offDefault = style.set({ Layered: { fg: "fg", bold: true } }, { default: true });
  const early = style.resolve("Layered").fg === baseDanger && style.resolve("Layered").bold === true;
  setFirst();
  const restored = style.resolve("Layered").fg === "reset";
  const setLater = style.set({ Layered: { bold: null } });
  const cleared = style.resolve("Layered").bold === undefined;
  setLater();
  offDefault();
  check("style-set-over-default", early && restored && cleared && !("Layered" in style.groups));
}

// The one theme sits below every set, a new theme replaces it, and a replaced theme's dispose does nothing, even for the same object.
{
  const user = style.set({ Normal: { bold: true } });
  const DARK = { groups: { Normal: { fg: "#101010", bold: false } }, palette: { danger: "#ff0000" } };
  const first = style.theme(DARK);
  const themed = style.resolve("Normal").fg === "#101010" && style.resolve("Normal").bold === true && style.palette.danger === "#ff0000";
  const light = style.theme({ groups: { Normal: { fg: "#f0f0f0" } } });
  const switched = style.resolve("Normal").fg === "#f0f0f0" && style.palette.danger === baseDanger;
  const again = style.theme(DARK);
  first();
  light();
  const kept = style.resolve("Normal").fg === "#101010";
  again();
  user();
  check("style-theme", themed && switched && kept && style.resolve("Normal").fg === "reset" && style.resolve("Normal").bold === undefined);
}

// A link gives its fields, and the group's own fields win.
{
  const off = style.set({ LinkBase: { fg: "danger", bold: true, underline: true }, LinkChild: { link: "LinkBase", bold: false } }, { default: true });
  const child = style.resolve("LinkChild");
  off();
  check("style-link-inherits", child.fg === baseDanger && child.underline === true && child.bold === undefined);
}

// A second default for a name, core or not, throws and changes nothing.
{
  let refused = false;
  try { style.set({ Fresh: { bold: true }, Normal: { fg: "danger" } }, { default: true }); } catch (e) { refused = e instanceof TypeError; }
  check("style-default-conflict", refused && !("Fresh" in style.groups) && style.resolve("Normal").fg === "reset");
}

// A plugin's groups and changes unload with the plugin.
{
  const stop = plugins.use({ name: "theme", apply: (c) => { const s = tui.bindTo(c).style; s.set({ toString: { bold: true } }, { default: true }); s.set({ Normal: { bold: true } }); } });
  const on = style.resolve("toString").bold === true && style.resolve("Normal").bold === true;
  stop.dispose();
  check("style-plugin-unload", on && !("toString" in style.groups) && style.resolve("Normal").bold === undefined);
}
