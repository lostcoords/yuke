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
