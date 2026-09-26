// Binary units match the blob size limit.
/** @param {number} n @returns {string} */
export function byteLabel(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KiB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
}

/** The message of a thrown value. A rejection can carry any value, so one without a message reads as its string. */
/** @param {unknown} error @returns {string} */
export function errorText(error) {
  if (error instanceof Error) return error.message;
  if (error !== null && typeof error === "object" && "message" in error) return String(error.message);
  return String(error);
}

// A duration as "12s" or "1m05s". A negative span reads as zero.
/** @param {number} ms @returns {string} */
export function elapsedLabel(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  const rest = s % 60;
  return m + "m" + (rest < 10 ? "0" : "") + rest + "s";
}

/** The words for the child runs the process carries, or "" without one. */
/** @param {number} count @returns {string} */
export function agentsLabel(count) {
  return count > 0 ? count + (count === 1 ? " agent" : " agents") : "";
}

// Round a token count to a short label, such as "2.5k".
/** @param {number} n @returns {string} */
export function tokenLabel(n) {
  if (n < 1000) return String(n);
  return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
}

/** @param {number} n @returns {string} */
export function money(n) {
  return "$" + n.toFixed(n < 1 ? 3 : 2);
}

export const BAR_CELLS = 6;
// The full and the empty glyph. Block Elements by default, because the terminal draws them and a font glyph can bleed.
/** @type {readonly [string, string]} */
export const BAR_GLYPHS = ["█", "░"];

// A bar of `cells` glyphs in proportion. `glyphs` holds the full glyph, then the empty one.
/** @param {number} used @param {number} window @param {number} [cells] @param {string | readonly [string, string]} [glyphs] @returns {string} */
export function contextBar(used, window, cells = BAR_CELLS, glyphs = BAR_GLYPHS) {
  const full = window > 0 ? Math.round(Math.min(1, used / window) * cells) : 0;
  const pair = typeof glyphs === "string" ? Array.from(glyphs) : glyphs;
  return "[" + String(pair[0]).repeat(full) + String(pair[1]).repeat(cells - full) + "]";
}
