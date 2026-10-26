/**
 * Key specs and key strokes. `parseKeys` folds a written spec and `strokeOf` folds a key event, so the two always
 * agree.
 */
import type { KeyEvent } from "yuke:tui";

const SHIFT = 1;
const ALT = 2;
const CTRL = 4;
const SUPER = 8;
/** Hyper and meta: no spec names them, so a key with one of them takes no binding. */
const OTHER = 16 | 32;

/** The named keys: the codes of the host, and `space`. */
const NAMED = new Set([
  "enter",
  "tab",
  "backspace",
  "esc",
  "insert",
  "delete",
  "left",
  "right",
  "up",
  "down",
  "page_up",
  "page_down",
  "home",
  "end",
  "menu",
  "space",
  ...Array.from({ length: 35 }, (_, index) => `f${index + 1}`),
]);

/** The strokes of `spec`. A spec that names no key throws a `TypeError`. */
export function parseKeys(spec: string): string[] {
  if (typeof spec !== "string") throw new TypeError("a key spec is a string");
  const strokes = spec.split(/\s+/).filter((stroke) => stroke !== "");
  if (strokes.length === 0) throw new TypeError(`'${spec}' names no key`);
  return strokes.map((stroke) => parseStroke(spec, stroke));
}

/** The stroke of `event`, or "" for a key that no spec names. */
export function strokeOf(event: KeyEvent): string {
  const { code, char, shifted, mods } = event;
  if ((mods & OTHER) !== 0) return "";
  const ctrl = (mods & CTRL) !== 0;
  const alt = (mods & ALT) !== 0;
  const superKey = (mods & SUPER) !== 0;
  let shift = (mods & SHIFT) !== 0;
  let key: string;
  if (code === "char") {
    if (char === "") return "";
    if (ctrl || alt || superKey) {
      // A legacy terminal cannot tell ctrl+G from ctrl+g, so another modifier folds the case.
      key = char.toLowerCase();
    } else {
      // A kitty terminal reports the shifted key apart; a legacy terminal sends the shifted character.
      key = shift ? shifted || char.toUpperCase() : char;
    }
    shift = false;
    if (key === " ") key = "space";
  } else if (NAMED.has(code)) {
    key = code;
  } else {
    return "";
  }
  return join(ctrl, alt, superKey, shift, key);
}

function parseStroke(spec: string, stroke: string): string {
  // The text after the last `+` is the key, so `ctrl++` is ctrl and `+`.
  const cut = stroke.endsWith("+") ? stroke.length - 2 : stroke.lastIndexOf("+");
  let key = stroke.slice(cut + 1);
  const modifiers = cut < 0 ? [] : stroke.slice(0, cut).split("+");
  let ctrl = false;
  let alt = false;
  let superKey = false;
  let shift = false;
  for (const modifier of modifiers) {
    if (modifier === "ctrl") ctrl = true;
    else if (modifier === "alt") alt = true;
    else if (modifier === "super") superKey = true;
    else if (modifier === "shift") shift = true;
    else throw new TypeError(`'${spec}': '${modifier}' is no modifier: ctrl, alt, super, or shift`);
  }
  if ([...key].length === 1) {
    if (ctrl || alt || superKey) {
      key = key.toLowerCase();
    } else if (shift) {
      // A kitty terminal reports shift+1 as `!`, so a shifted symbol has only its own spec.
      if (key.toUpperCase() === key.toLowerCase()) {
        throw new TypeError(`'${spec}': write the shifted character itself, such as '!' for shift+1`);
      }
      key = key.toUpperCase();
    }
    shift = false;
  } else if (key === "space") {
    // `strokeOf` reads space as a character, so shift drops as for a character.
    shift = false;
  } else if (!NAMED.has(key)) {
    throw new TypeError(`'${spec}': '${key}' is no key: one character, or a name such as enter, esc, or space`);
  }
  return join(ctrl, alt, superKey, shift, key);
}

function join(ctrl: boolean, alt: boolean, superKey: boolean, shift: boolean, key: string): string {
  return `${ctrl ? "ctrl+" : ""}${alt ? "alt+" : ""}${superKey ? "super+" : ""}${shift ? "shift+" : ""}${key}`;
}
