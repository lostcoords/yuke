/** @param {unknown} actual @param {unknown} expected @returns {void} */
export function equal(actual, expected) {
  if (!Object.is(actual, expected)) {
    throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

/** @param {string} name @param {unknown} value @returns {void} */
export function check(name, value) {
  if (!value) throw new Error(name);
}

// A part reader over plain text: one text part for each message, or none for an empty text.
/** @param {(id: any) => string} textOf @returns {(id: any) => { type: "text", id: number, text: string }[]} */
export function textParts(textOf) {
  return (id) => {
    const text = textOf(id);
    return text ? [{ type: "text", id: 0, text }] : [];
  };
}
