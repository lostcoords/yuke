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
export function thousands(n) {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** @param {number} n @returns {string} */
export function money(n) {
  const size = Math.abs(n);
  const text = size.toFixed(size < 1 ? 3 : 2);
  // A float sum can leave a tiny negative rest, and "-$0.000" would claim a loss that is not there.
  return (n < 0 && Number(text) !== 0 ? "-$" : "$") + text;
}

// The cost of a session. An unpriced turn makes the sum a floor, so the label says so and does not guess.
/** @param {Wire.SessionCost} cost @returns {string} */
export function costLabel(cost) {
  if (cost.unpriced === 0) return money(cost.total);
  return "≥ " + money(cost.total) + " · " + cost.unpriced + (cost.unpriced === 1 ? " turn" : " turns") + " unpriced";
}

// A bar of `cells` glyphs in proportion. Block Elements, because the terminal draws them and a font glyph can bleed.
/** @param {number} used @param {number} window @param {number} [cells] @returns {string} */
export function contextBar(used, window, cells = 6) {
  const full = window > 0 ? Math.round(Math.min(1, used / window) * cells) : 0;
  return "[" + "█".repeat(full) + "░".repeat(cells - full) + "]";
}
