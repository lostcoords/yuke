// Binary units match the blob size limit.
/** @param {number} n @returns {string} */
export function byteLabel(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KiB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
}

// The UTF-8 size of a string. A lone surrogate counts as the three bytes of its replacement.
/** @param {string} text @returns {number} */
export function utf8Length(text) {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) bytes += 1;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else bytes += 3;
  }
  return bytes;
}

/** The message of a thrown value. A rejection can carry any value, so one without a message reads as its string. */
/** @param {unknown} error @returns {string} */
export function errorText(error) {
  if (error instanceof Error) return error.message;
  if (error !== null && typeof error === "object" && "message" in error) return String(error.message);
  return String(error);
}
