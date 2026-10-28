/** The code of the public module `yuke:test`. Its declaration is `types/test.d.ts`, and the check at the end compares the two. */

import { createHost, reply } from "yuke:internal/host";
import { folder, register } from "yuke:internal/test";

export { createHost, folder, reply };

/** The most characters of a value in a failure. */
const SHOWN = 200;

/** A short text of `value` for a failure. */
function show(value: unknown): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") return Object.is(value, -0) ? "-0" : String(value);
  if (typeof value !== "object" || value === null) return String(value);
  let text: string;
  try {
    text = JSON.stringify(value, (_key, item: unknown) => {
      if (item instanceof Map) return { Map: [...item] };
      if (item instanceof Set) return { Set: [...item] };
      if (ArrayBuffer.isView(item) && !(item instanceof DataView)) return [...(item as Uint8Array)];
      return typeof item === "bigint" ? `${item}n` : item;
    });
  } catch {
    text = Object.prototype.toString.call(value);
  }
  return text.length > SHOWN ? `${text.slice(0, SHOWN)}…` : text;
}

/** The path of the key `key` below `path`. */
function child(path: string, key: string | symbol | number): string {
  if (typeof key === "number") return `${path}[${key}]`;
  if (typeof key === "symbol") return `${path}[${String(key)}]`;
  return /^[A-Za-z_$][\w$]*$/.test(key) ? `${path}.${key}` : `${path}[${JSON.stringify(key)}]`;
}

/** The first difference between `actual` and `expected` at `path`, or `undefined` when they are equal. */
function difference(actual: unknown, expected: unknown, path: string): string | undefined {
  if (Object.is(actual, expected)) return undefined;
  const at = path === "" ? "the value" : path;
  const differ = `at ${at}: expected ${show(expected)}, got ${show(actual)}`;
  if (typeof actual !== "object" || actual === null || typeof expected !== "object" || expected === null) {
    return differ;
  }
  if (Object.getPrototypeOf(actual) !== Object.getPrototypeOf(expected)) return `${differ} (another prototype)`;
  if (expected instanceof Date) return (actual as Date).getTime() === expected.getTime() ? undefined : differ;
  if (expected instanceof Map) {
    const map = actual as Map<unknown, unknown>;
    if (map.size !== expected.size) return `at ${at}: expected ${expected.size} entries, got ${map.size}`;
    for (const [key, value] of expected) {
      const keyPath = `${path}.get(${show(key)})`;
      if (!map.has(key)) return `at ${keyPath}: expected ${show(value)}, got no entry`;
      const found = difference(map.get(key), value, keyPath);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  if (expected instanceof Set) {
    const set = actual as Set<unknown>;
    if (set.size !== expected.size) return `at ${at}: expected ${expected.size} values, got ${set.size}`;
    for (const value of expected) {
      // An object value can equal an item that is another object.
      const found = set.has(value) || [...set].some((item) => difference(item, value, "") === undefined);
      if (!found) return `at ${at}: expected the value ${show(value)}, got none`;
    }
    return undefined;
  }
  if (Array.isArray(expected) || ArrayBuffer.isView(expected)) {
    const items = actual as ArrayLike<unknown>;
    const wanted = expected as ArrayLike<unknown>;
    if (items.length !== wanted.length) return `at ${at}: expected ${wanted.length} items, got ${items.length}`;
    for (let index = 0; index < wanted.length; index += 1) {
      const found = difference(items[index], wanted[index], child(path, index));
      if (found !== undefined) return found;
    }
    return undefined;
  }
  const object = actual as Record<string | symbol, unknown>;
  const wanted = expected as Record<string | symbol, unknown>;
  const keys = (value: object): (string | symbol)[] =>
    Reflect.ownKeys(value).filter((key) => Object.prototype.propertyIsEnumerable.call(value, key));
  // The name and the message of an error are no enumerable keys, but they tell two errors apart.
  if (expected instanceof Error) {
    for (const key of ["name", "message"]) {
      const found = difference(object[key], wanted[key], child(path, key));
      if (found !== undefined) return found;
    }
  }
  for (const key of keys(wanted)) {
    if (!Object.hasOwn(object, key)) return `at ${child(path, key)}: expected ${show(wanted[key])}, got no key`;
    const found = difference(object[key], wanted[key], child(path, key));
    if (found !== undefined) return found;
  }
  for (const key of keys(object)) {
    if (!Object.hasOwn(wanted, key)) return `at ${child(path, key)}: expected no key, got ${show(object[key])}`;
  }
  return undefined;
}

export function test(name: string, fn: () => void | Promise<void>): void {
  register(name, fn);
}

export function assert(condition: unknown, message?: string): asserts condition {
  if (!condition) throw new Error(message ?? "assert: the condition is false");
}

export function equal(actual: unknown, expected: unknown, message?: string): void {
  const found = difference(actual, expected, "");
  if (found !== undefined) throw new Error(`${message === undefined ? "equal" : message}: ${found}`);
}

export function throws(fn: () => unknown): unknown {
  try {
    fn();
  } catch (error) {
    return error;
  }
  throw new Error("throws: the function returned");
}

export async function rejects(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("rejects: the promise fulfilled");
}

// The check against `types/test.d.ts` keeps this code and the declarations of the authors in step.
const declared = {
  test,
  assert,
  equal,
  throws,
  rejects,
  folder,
  createHost,
  reply,
} satisfies typeof import("yuke:test");
void declared;
