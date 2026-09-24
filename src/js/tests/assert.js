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

/** Poll a condition with no event until it holds or five seconds pass. @param {() => boolean | Promise<boolean>} ready @param {string} [name] @returns {Promise<void>} */
export async function until(ready, name = "condition") {
  const deadline = Date.now() + 5000;
  while (!(await ready())) {
    if (Date.now() >= deadline) throw new Error(`${name} did not become ready`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

// A part reader over plain text: one text part for each message, or none for an empty text.
/** @param {(id: any) => string} textOf @returns {(id: any) => { type: "text", id: number, text: string }[]} */
export function textParts(textOf) {
  return (id) => {
    const text = textOf(id);
    return text ? [{ type: "text", id: 0, text }] : [];
  };
}
