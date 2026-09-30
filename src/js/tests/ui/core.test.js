import { check, equal } from "yuke:internal/test";
import { style } from "yuke:internal/core";
import { clip } from "yuke:internal/text-input";
for (const [text, width, expected] of [["", 3, ""], ["abc", 0, ""], ["abc", 10, "abc"], ["abc", 1, "a"], ["abcd", 3, "ab…"], ["中文", 3, "中…"]]) {
  equal(clip(text, width), expected);
}
equal(style.resolve("Normal").fg, "reset");
{
  const off = style.setPalette({ fg: "red" });
  equal(style.resolve("Normal").fg, "red");
  equal(style.resolve("YukeStatus").fg, "red");
  check("status is dim", style.resolve("YukeStatus").dim === true);
  check("brand is bold", style.resolve("YukeBrand").bold === true);
  off();
  equal(style.resolve("Normal").fg, "reset");
}

{
  const palette = style.setPalette({ accent: "#12aBcD", 0: "red" });
  const off = style.set({
    RgbLiteral: { fg: "#000000", bg: "#ffffff", ul: "#123456", underline: true },
    RgbPalette: { fg: "accent", bg: "accent", ul: "accent" },
    RgbLink: { link: "RgbPalette", fg: "red" },
    IndexLiteral: { fg: 0, bg: 255, ul: 1 },
    OwnPalette: { fg: "toString", bg: "constructor", ul: "__proto__" },
  }, { default: true });
  const literal = style.resolve("RgbLiteral");
  equal(literal.fg, "#000000");
  equal(literal.bg, "#ffffff");
  equal(literal.ul, "#123456");
  check("RGB underline flag", literal.underline === true);
  const linked = style.resolve("RgbLink");
  equal(linked.fg, "red");
  equal(linked.bg, "#12aBcD");
  const resolved = style.resolve("RgbPalette");
  equal(resolved.ul, "#12aBcD");
  check("RGB cache identity", style.resolve("RgbPalette") === resolved);
  const recolor = style.setPalette({ accent: "#654321" });
  equal(style.resolve("RgbPalette").fg, "#654321");
  equal(style.resolve("RgbLink").bg, "#654321");
  recolor();
  equal(style.resolve("RgbPalette").fg, "#12aBcD");
  const indexed = style.resolve("IndexLiteral");
  equal(indexed.fg, 0);
  equal(indexed.bg, 255);
  equal(indexed.ul, 1);
  const own = style.resolve("OwnPalette");
  equal(own.fg, "toString");
  equal(own.bg, "constructor");
  equal(own.ul, "__proto__");
  off();
  palette();
}

let reserved = false;
try { style.set({ "\0internal": { bold: true } }); } catch (error) { reserved = error instanceof TypeError; }
check("internal-style-name-is-reserved", reserved && !("\0internal" in style.groups));
