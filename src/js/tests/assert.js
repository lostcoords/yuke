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
