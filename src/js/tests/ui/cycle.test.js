import { style } from "yuke:core";
style.groups.Cycle = { link: "Pong" };
style.groups.Pong = { link: "Cycle" };
style.groups.Selfie = { link: "Selfie" };
style.groups.Dangling = { link: "Missing" };
style.invalidate();
const normal = style.resolve("Normal");
globalThis.result = (
  style.resolve("Cycle").fg === normal.fg &&
  style.resolve("Selfie").fg === normal.fg &&
  style.resolve("Dangling").fg === normal.fg &&
  style.resolve("YukeHeader").fg === "reset" &&
  style.resolve("YukeHeader").dim === true
) ? 1 : 0;
