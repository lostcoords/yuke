// Normalize terminal key events and configured strokes.

// The window keys under one leader: move the focus, split, and close.
/** @param {string} leader @returns {Record<string, string>} */
export function windowKeys(leader) {
  const map = { h: "focus:left", j: "focus:down", k: "focus:up", l: "focus:right", left: "focus:left", down: "focus:down", up: "focus:up", right: "focus:right", w: "focus:next", v: "window:split-right", s: "window:split-down", c: "window:close" };
  return Object.fromEntries(Object.entries(map).map(([key, name]) => [leader + " " + key, name]));
}
// Fold a written sequence stroke by stroke. White space separates the strokes, as `\s` reads it, and a scan needs no RegExp.
/** @param {string} seq @returns {string} */
export function normalizeSeq(seq) {
  let out = "";
  let count = 0;
  let start = -1;
  for (let i = 0; i <= seq.length; i++) {
    if (i < seq.length && !isSpace(seq.charCodeAt(i))) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      if (count > 0) out += " ";
      out += normalizeStroke(seq.slice(start, i));
      count++;
      start = -1;
    }
  }
  // A sequence of white space alone names that key, such as " " for space.
  return count === 0 ? normalizeStroke(seq) : out;
}

// The ECMAScript white space and line terminators: the set `\s` and `trim` use.
/** @param {number} c @returns {boolean} */
function isSpace(c) {
  return c === 32 || (c >= 9 && c <= 13) || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a) ||
    c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff;
}

/** @param {string} stroke @returns {string} */
export function stripCtrl(stroke) {
  return stroke.indexOf("ctrl+") === 0 ? stroke.slice(5) : stroke;
}

const MOD_SHIFT = 1;
const MOD_ALT = 2;
const MOD_CTRL = 4;
const MOD_SUPER = 8;

/** @param {boolean} ctrl @param {boolean} alt @param {boolean} sup @param {boolean} shift @param {string} token @returns {string} */
function joinStroke(ctrl, alt, sup, shift, token) {
  return (ctrl ? "ctrl+" : "") + (alt ? "alt+" : "") + (sup ? "super+" : "") + (shift ? "shift+" : "") + token;
}

// The stroke a binding matches. A char key carries its own case, so `G` and `g` differ.
/** @param {Extract<HostEvent, { type: "key" }>} ev @returns {string} */
export function strokeOf(ev) {
  const m = ev.mods | 0;
  const ctrl = (m & MOD_CTRL) !== 0;
  const alt = (m & MOD_ALT) !== 0;
  const sup = (m & MOD_SUPER) !== 0;
  let shift = (m & MOD_SHIFT) !== 0;
  let token;
  if (ev.code === "char") {
    token = ev.char || "";
    if (!token) return "";
    if (ctrl || alt || sup) {
      // A terminal cannot report ctrl+G apart from ctrl+g, so another modifier folds the case.
      token = token.toLowerCase();
      shift = false;
    } else {
      // The kitty protocol reports the shifted form apart; a legacy terminal sends the shifted char.
      if (shift) token = ev.shifted || token.toUpperCase();
      shift = false;
    }
  } else {
    token = ev.code;
  }
  if (!token) return "";
  return joinStroke(ctrl, alt, sup, shift, token);
}

// Return committed text. Use the folded key only for an unmodified legacy event.
/** @param {HostEvent} ev @returns {string} */
export function textOf(ev) {
  if (ev.type === "paste") return ev.text || "";
  if (ev.type !== "key" || ev.code !== "char") return "";
  if (ev.text) return ev.text;
  if (((ev.mods | 0) & (MOD_CTRL | MOD_ALT | MOD_SUPER)) !== 0) return "";
  return ev.char || "";
}

// Fold a written binding the way `strokeOf` folds an event, so the two always agree.
/** @param {string} stroke @returns {string} */
function normalizeStroke(stroke) {
  // The text after the last "+" is the key; each part before it names a modifier.
  const cut = stroke.lastIndexOf("+");
  let token = stroke.slice(cut + 1);
  let ctrl = false, alt = false, sup = false, shift = false;
  for (let from = 0; from <= cut; ) {
    const to = stroke.indexOf("+", from);
    const name = stroke.slice(from, to).toLowerCase();
    if (name === "ctrl" || name === "control") ctrl = true;
    else if (name === "alt") alt = true;
    else if (name === "super") sup = true;
    else if (name === "shift") shift = true;
    from = to + 1;
  }
  // A named key such as `tab` has no case. A char key keeps its own, and shift folds into it.
  if (token.length > 1) token = token.toLowerCase();
  else if (ctrl || alt || sup) {
    token = token.toLowerCase();
    shift = false;
  }
  else if (shift) {
    token = token.toUpperCase();
    shift = false;
  }
  return joinStroke(ctrl, alt, sup, shift, token);
}
