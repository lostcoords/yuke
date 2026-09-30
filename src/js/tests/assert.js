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

// Answer the session list with `items` and let the session layer read it, as an overflow makes it do. The sessions plugin must run.
/** @param {unknown[]} items @returns {Promise<void>} */
export async function listSessions(items) {
  const { client } = await import("yuke:internal/client");
  const { events } = await import("yuke:internal/kernel");
  const { defaultModel } = await import("yuke:internal/session");
  client.sessionList = async () => /** @type {any} */ ({ items });
  events.emit("index.changed", { type: "index", overflow: true, facts: [] });
  defaultModel();
  for (let i = 0; i < 8; i++) await Promise.resolve();
}

// The sections that a details window shows, as `{ label, text }`. A wide width keeps each source line on one row.
/** @param {{ rowsFor: (width: number) => any[] }} view @returns {{ label: string, text: string }[]} */
export function detailSections(view) {
  const out = [];
  for (const row of view.rowsFor(1 << 20)) {
    if (row.group === "TxToolTitle") out.push({ label: row.text, lines: [] });
    else if ((row.segments || row.src != null) && out.length) out[out.length - 1].lines.push(row.segments ? row.segments.map((seg) => seg.text).join("") : row.text);
  }
  return out.map((section) => ({ label: section.label, text: section.lines.join("\n") }));
}
