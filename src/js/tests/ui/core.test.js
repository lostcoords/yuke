import { check, equal } from "yuke:test";
import { style } from "yuke:core";
import { clip } from "yuke:text-input";
for (const [text, width, expected] of [["", 3, ""], ["abc", 0, ""], ["abc", 10, "abc"], ["abc", 1, "a"], ["abcd", 3, "ab…"], ["中文", 3, "中…"]]) {
  equal(clip(text, width), expected);
}
equal(style.resolve("Normal").fg, "reset");
style.palette.fg = "red";
equal(style.resolve("Normal").fg, "reset");
style.invalidate();
equal(style.resolve("Normal").fg, "red");
equal(style.resolve("YukeHeader").fg, "red");
check("header is dim", style.resolve("YukeHeader").dim === true);
check("brand is bold", style.resolve("YukeBrand").bold === true);

{
  style.palette.accent = "#12aBcD";
  style.palette[0] = "red";
  const off = style.add({
    RgbLiteral: { fg: "#000000", bg: "#ffffff", ul: "#123456", underline: true },
    RgbPalette: { fg: "accent", bg: "accent", ul: "accent" },
    RgbLink: { link: "RgbPalette", fg: "red" },
    IndexLiteral: { fg: 0, bg: 255, ul: 1 },
    OwnPalette: { fg: "toString", bg: "constructor", ul: "__proto__" },
  });
  const literal = style.resolve("RgbLiteral");
  equal(literal.fg, "#000000");
  equal(literal.bg, "#ffffff");
  equal(literal.ul, "#123456");
  check("RGB underline flag", literal.underline === true);
  for (const name of ["RgbPalette", "RgbLink"]) {
    const resolved = style.resolve(name);
    equal(resolved.fg, "#12aBcD");
    equal(resolved.bg, "#12aBcD");
    equal(resolved.ul, "#12aBcD");
    check("RGB cache identity", style.resolve(name) === resolved);
  }
  style.palette.accent = "#654321";
  style.groups.RgbLiteral.ul = "#abcdef";
  equal(style.resolve("RgbLink").ul, "#12aBcD");
  equal(style.resolve("RgbLiteral").ul, "#123456");
  style.invalidate();
  for (const name of ["RgbPalette", "RgbLink"]) {
    const resolved = style.resolve(name);
    equal(resolved.fg, "#654321");
    equal(resolved.bg, "#654321");
    equal(resolved.ul, "#654321");
  }
  equal(style.resolve("RgbLiteral").ul, "#abcdef");
  const indexed = style.resolve("IndexLiteral");
  equal(indexed.fg, 0);
  equal(indexed.bg, 255);
  equal(indexed.ul, 1);
  const own = style.resolve("OwnPalette");
  equal(own.fg, "toString");
  equal(own.bg, "constructor");
  equal(own.ul, "__proto__");
  off();
  delete style.palette.accent;
  delete style.palette[0];
  style.invalidate();
}
