// The copies of the values that plugins give the host.

/** A copy of the JSON value `value`, so a later change by the plugin does not reach the host. */
export function jsonCopy<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

/** `value` with each object in it frozen. A JSON value has no cycle. */
export function frozen<T>(value: T): T {
  // A typed array with items cannot freeze, so the bytes of a `ToolMedia` stay as they are.
  if (typeof value === "object" && value !== null && !ArrayBuffer.isView(value)) {
    for (const inner of Object.values(value)) frozen(inner);
    Object.freeze(value);
  }
  return value;
}
