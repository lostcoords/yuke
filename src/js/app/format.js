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
