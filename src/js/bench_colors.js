import { term } from "yuke:term";
import { style } from "yuke:core";

/** @import { RgbColor, Style } from "yuke:term" */

let width = 0, height = 0, colors = "ansi_raw";
/** @type {Required<Pick<Style, "fg" | "bg" | "ul" | "underline">>} */
let colorStyle = { fg: "reset", bg: "reset", ul: "reset", underline: true };

/** @param {string} _name @param {number} _scale @param {number} w @param {number} h @param {string} [colorMode] */
function start(_name, _scale, w, h, colorMode = "ansi_raw") {
  width = w;
  height = h;
  colors = colorMode;
  colorStyle = colors.startsWith("rgb")
    ? { fg: "#80a0c0", bg: "#182028", ul: "#e06060", underline: true }
    : { fg: "white", bg: "black", ul: "red", underline: true };
  style.palette.benchFg = colorStyle.fg;
  style.palette.benchBg = colorStyle.bg;
  style.palette.benchUl = colorStyle.ul;
  style.groups.BenchLiteral = { ...colorStyle };
  style.groups.BenchPalette = { fg: "benchFg", bg: "benchBg", ul: "benchUl", underline: true };
  style.invalidate();
  return step();
}

/** @param {number} value @returns {RgbColor} */
function hexColor(value) {
  return `#${value.toString(16).padStart(6, "0")}`;
}

function step() {
  term.beginFrame();
  for (let y = 0; y < height; y++) {
    const resolved = colors.endsWith("group") ? style.resolve(y & 1 ? "BenchPalette" : "BenchLiteral") : colorStyle;
    if (colors === "rgb_fresh") {
      colorStyle.fg = hexColor(0x80a0c0);
      colorStyle.bg = hexColor(0x182028);
      colorStyle.ul = hexColor(0xe06060);
    }
    term.fill(0, y, width, 1, resolved);
    term.text(0, y, "color sample", resolved);
  }
  term.endFrame();
  return height;
}

globalThis.bench = { start, step, verify: step };
