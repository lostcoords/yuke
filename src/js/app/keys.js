// Normalize terminal key events and configured strokes.
/** @param {string} seq @returns {string} */
export function normalizeSeq(seq) {
  const s = String(seq);
  if (s.trim() === "") return normalizeStroke(s);
  return s.trim().split(/\s+/).map(normalizeStroke).join(" ");
}

/** @param {string} stroke @returns {string} */
export function stripCtrl(stroke) {
  return stroke.indexOf("ctrl+") === 0 ? stroke.slice(5) : stroke;
}

const MOD_SHIFT = 1;
const MOD_ALT = 2;
const MOD_CTRL = 4;
const MOD_SUPER = 8;

/** @param {{ ctrl: boolean, alt: boolean, super: boolean, shift: boolean }} mods @param {string} token @returns {string} */
function joinStroke(mods, token) {
  const parts = [];
  if (mods.ctrl) parts.push("ctrl");
  if (mods.alt) parts.push("alt");
  if (mods.super) parts.push("super");
  if (mods.shift) parts.push("shift");
  parts.push(token);
  return parts.join("+");
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
  return joinStroke({ ctrl, alt, super: sup, shift }, token);
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
  const parts = String(stroke).split("+");
  let token = /** @type {string} */ (parts.pop() ?? "");
  const mods = /** @type {{ ctrl: boolean, alt: boolean, super: boolean, shift: boolean } & Record<string, boolean>} */ ({ ctrl: false, alt: false, super: false, shift: false });
  for (const p of parts) {
    const name = p.toLowerCase();
    if (name === "control") mods.ctrl = true;
    else if (name in mods) mods[name] = true;
  }
  // A named key such as `tab` has no case. A char key keeps its own, and shift folds into it.
  if (token.length > 1) token = token.toLowerCase();
  else if (mods.ctrl || mods.alt || mods.super) {
    token = token.toLowerCase();
    mods.shift = false;
  }
  else if (mods.shift) {
    token = token.toUpperCase();
    mods.shift = false;
  }
  return joinStroke(mods, token);
}
