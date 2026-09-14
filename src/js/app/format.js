// Binary units match the blob size limit.
/** @param {number} n @returns {string} */
export function byteLabel(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KiB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
}
