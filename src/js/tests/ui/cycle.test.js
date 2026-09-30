import { style } from "yuke:internal/core";
style.set({ Cycle: { link: "Pong" }, Pong: { link: "Cycle" }, Selfie: { link: "Selfie" }, Dangling: { link: "Missing" }, Linked: { link: "YukeStatus" } }, { default: true });
const normal = style.resolve("Normal");
globalThis.result = (
  style.resolve("Cycle").fg === normal.fg &&
  style.resolve("Selfie").fg === normal.fg &&
  style.resolve("Dangling").fg === normal.fg &&
  style.resolve("Linked").fg === "reset" &&
  style.resolve("Linked").dim === true
) ? 1 : 0;
