import { style } from "yuke:core";
import { clip } from "yuke:text-input";
const before = style.resolve("Normal").fg;
style.palette.fg = "red";
const stale = style.resolve("Normal").fg;
style.invalidate();
globalThis.result = (
  clip("", 3) === "" &&
  clip("abc", 0) === "" &&
  clip("abc", 10) === "abc" &&
  clip("abc", 1) === "a" &&
  clip("abcd", 3) === "ab…" &&
  clip("中文", 3) === "中…" &&
  before === "reset" &&
  stale === "reset" &&
  style.resolve("Normal").fg === "red" &&
  style.resolve("YukeHeader").fg === "red" &&
  style.resolve("YukeHeader").dim === true &&
  style.resolve("YukeBrand").bold === true
) ? 1 : 0;
