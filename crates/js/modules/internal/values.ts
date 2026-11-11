// The checked copies of the values that plugins give the host: objects with known fields, JSON values, and media.

import type { ToolMedia } from "yuke:tools";

/** The fields of one media item. */
const MEDIA_FIELDS = ["mimeType", "path", "bytes"];

/** The checked copy of the media item `value`. `place` names it in the error. A value of another shape throws. */
export function mediaOf(value: unknown, place: string): ToolMedia {
  const fields = fieldsOf(value, place, MEDIA_FIELDS);
  const mimeType = fields.mimeType;
  if (typeof mimeType !== "string") throw new TypeError(`${place}.mimeType is not a string`);
  if (Object.hasOwn(fields, "path") === Object.hasOwn(fields, "bytes")) {
    throw new TypeError(`${place} needs exactly one of path and bytes`);
  }
  if (Object.hasOwn(fields, "path")) {
    if (typeof fields.path !== "string") throw new TypeError(`${place}.path is not a string`);
    return { mimeType, path: fields.path };
  }
  if (!(ArrayBuffer.isView(fields.bytes) && fields.bytes instanceof Uint8Array))
    throw new TypeError(`${place}.bytes is not a Uint8Array`);
  // A copy through the constructor, so a later change of the bytes by the plugin does not change the result.
  return { mimeType, bytes: new Uint8Array(fields.bytes) };
}

/**
 * A copy of the JSON value `value`, so a later change by the plugin does not reach the host. JSON would turn a number
 * that is not finite into `null` and drop a symbol or a function, so each throws a `TypeError` that names `place`.
 */
export function jsonCopy<T>(value: T, place: string): T {
  const text = JSON.stringify(value, (_key, item: unknown) => {
    if (typeof item === "number" && !Number.isFinite(item)) {
      throw new TypeError(`${place} holds a number that is not finite`);
    }
    if (typeof item === "symbol" || typeof item === "function") {
      throw new TypeError(`${place} holds a ${typeof item}, which JSON cannot hold`);
    }
    return item;
  });
  return JSON.parse(text) as T;
}

/**
 * A copy of the own fields of the object `value`. A value that is not an object, a symbol key, or a field outside
 * `names` throws. An inherited field does not count.
 */
export function fieldsOf(value: unknown, place: string, names: readonly string[]): Readonly<Record<string, unknown>> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError(`${place} is not an object`);
  }
  const fields: Record<string, unknown> = {};
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== "string") throw new TypeError(`${place} has a symbol key`);
    if (!names.includes(key)) throw new TypeError(`${place} has the unknown field '${key}'`);
    fields[key] = (value as Record<string, unknown>)[key];
  }
  return fields;
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
