/**
 * The Web IDL conversions of the internal web classes, and the built-in functions that they keep from the start of the
 * runtime, so a plugin that patches a prototype does not change them.
 */

export const ByteArray = Uint8Array;

const bindCall = Function.prototype.bind.bind(Function.prototype.call) as (fn: unknown) => unknown;

/**
 * `fn` as a function that takes its `this` as the first argument. Each call goes through the `call` of the runtime
 * start, so a later patch of `Function.prototype.call` does not see the call.
 */
export function uncurryThis<T, A extends unknown[], R>(fn: (this: T, ...args: A) => R): (self: T, ...args: A) => R {
  return bindCall(fn) as (self: T, ...args: A) => R;
}

const getter = (prototype: object, name: PropertyKey) =>
  uncurryThis(Object.getOwnPropertyDescriptor(prototype, name)?.get as (this: unknown) => unknown);
const typedArray: object = Object.getPrototypeOf(Uint8Array.prototype);
const typedArrayTag = getter(typedArray, Symbol.toStringTag);
const typedArrayBuffer = getter(typedArray, "buffer");
const typedArrayOffset = getter(typedArray, "byteOffset");
const typedArrayBytes = getter(typedArray, "byteLength");
const typedArrayLength = getter(typedArray, "length");
const dataViewBuffer = getter(DataView.prototype, "buffer");
const dataViewOffset = getter(DataView.prototype, "byteOffset");
const dataViewBytes = getter(DataView.prototype, "byteLength");
const bufferResizable = getter(ArrayBuffer.prototype, "resizable");
const bufferDetached = getter(ArrayBuffer.prototype, "detached");
const sharedGrowable =
  typeof SharedArrayBuffer === "function" ? getter(SharedArrayBuffer.prototype, "growable") : undefined;
const setBytes = uncurryThis((typedArray as { readonly set: (this: Uint8Array, bytes: Uint8Array) => void }).set);
const weakGet = uncurryThis(WeakMap.prototype.get);
const weakSet = uncurryThis(WeakMap.prototype.set);

/** A map of private state by object. It calls the `WeakMap` methods of the runtime start, so a patch sees no state. */
export class PrivateMap<K extends object, V> {
  readonly #map = new WeakMap<K, V>();

  get(key: unknown): V | undefined {
    return weakGet(this.#map, key as K) as V | undefined;
  }

  set(key: K, value: V): void {
    weakSet(this.#map, key, value);
  }
}

/** Throw a `TypeError` when `args` has fewer than `count` values, as Web IDL does for a missing argument. */
export function needs(args: readonly unknown[], count: number, name: string): void {
  if (args.length < count) throw new TypeError(`${name} needs ${count} argument${count === 1 ? "" : "s"}`);
}

/** Convert `value` as a Web IDL `DOMString`. A symbol throws a `TypeError`. */
export function domString(value: unknown): string {
  return `${value as string}`;
}

/** Convert `value` as a Web IDL dictionary: `undefined` and `null` are empty, another value that is not an object throws. */
export function dictionary(value: unknown, name: string): Readonly<Record<string, unknown>> {
  if (value === undefined || value === null) return {};
  if (typeof value !== "object" && typeof value !== "function") throw new TypeError(`${name} is not an object`);
  return value as Record<string, unknown>;
}

/** Give `type` the class string `name`, and make its members enumerable, as Web IDL does for an interface. */
export function webClass(type: { readonly prototype: object }, name: string): void {
  for (const key of Reflect.ownKeys(type.prototype)) {
    if (key !== "constructor") Object.defineProperty(type.prototype, key, { enumerable: true });
  }
  Object.defineProperty(type.prototype, Symbol.toStringTag, { value: name, configurable: true });
}

/** Whether `value` is a `Uint8Array`, by the brand of the engine. */
export function isUint8Array(value: unknown): value is Uint8Array {
  return typedArrayTag(value) === "Uint8Array";
}

/** The element count of `view`, a typed array, from the engine and not from a property that a script can shadow. */
export function lengthOf(view: Uint8Array): number {
  return typedArrayLength(view) as number;
}

/** Copy `bytes` into `target` from its start. */
export function copyInto(target: Uint8Array, bytes: Uint8Array): void {
  setBytes(target, bytes);
}

/** The result of `read` on `value`, or `undefined` when `read` throws because `value` lacks its brand. */
function branded(read: ((self: unknown) => unknown) | undefined, value: unknown): unknown {
  if (read === undefined) return undefined;
  try {
    return read(value);
  } catch {
    return undefined;
  }
}

/** A buffer, and the range of a view of it, all read from the engine. */
interface Source {
  readonly buffer: ArrayBufferLike;
  readonly offset: number;
  readonly length: number | undefined;
}

/**
 * The buffer and range of `value`, a Web IDL `AllowSharedBufferSource`: a buffer or a view of one. A resizable buffer
 * throws a `TypeError`. Gives `undefined` for a value of another type.
 */
function sourceOf(value: unknown, name: string): Source | undefined {
  let source: Source;
  const typed = branded(typedArrayBuffer, value);
  const data = typed === undefined ? branded(dataViewBuffer, value) : undefined;
  if (typed !== undefined) {
    // A detached view has no range, so its getters give 0.
    source = {
      buffer: typed as ArrayBufferLike,
      offset: typedArrayOffset(value) as number,
      length: typedArrayBytes(value) as number,
    };
  } else if (data !== undefined) {
    const detached = branded(bufferDetached, data) === true;
    source = {
      buffer: data as ArrayBufferLike,
      offset: detached ? 0 : (dataViewOffset(value) as number),
      length: detached ? 0 : (dataViewBytes(value) as number),
    };
  } else {
    source = { buffer: value as ArrayBufferLike, offset: 0, length: undefined };
  }
  // The engine makes no growable `SharedArrayBuffer`, so only an `ArrayBuffer` can be resizable.
  const resizable = branded(bufferResizable, source.buffer);
  if (resizable === true) throw new TypeError(`${name} has a resizable buffer`);
  const shared = branded(sharedGrowable, source.buffer) !== undefined;
  return resizable !== undefined || shared ? source : undefined;
}

/**
 * The bytes of `value`, a Web IDL `AllowSharedBufferSource`, as a `Uint8Array` over the same memory. A detached buffer
 * gives no bytes. A value of another type, or a resizable buffer, throws a `TypeError`.
 */
export function bytesOf(value: unknown, name: string): Uint8Array {
  const source = sourceOf(value, name);
  if (source === undefined) throw new TypeError(`${name} is not an ArrayBuffer, a SharedArrayBuffer, or a view of one`);
  if (branded(bufferDetached, source.buffer) === true) return new ByteArray(0);
  return new ByteArray(source.buffer, source.offset, source.length);
}

/** Check that `value` is a Web IDL `[AllowShared] Uint8Array` whose buffer is not resizable. */
export function checkUint8Array(value: unknown, name: string): asserts value is Uint8Array {
  if (!isUint8Array(value)) throw new TypeError(`${name} is not a Uint8Array`);
  sourceOf(value, name);
}
