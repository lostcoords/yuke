/** The Web IDL conversions of the internal web classes. */

/** Throw a `TypeError` when `args` has fewer than `count` values, as Web IDL does for a missing argument. */
export function needs(args: readonly unknown[], count: number, name: string): void {
  if (args.length < count) throw new TypeError(`${name} needs ${count} argument${count === 1 ? "" : "s"}`);
}

/** Convert `value` as a Web IDL `DOMString`. A symbol throws a `TypeError`. */
export function domString(value: unknown): string {
  return `${value as string}`;
}

/** Convert `value` as a Web IDL `USVString`: a symbol throws, and a lone surrogate becomes U+FFFD. */
export function usvString(value: unknown): string {
  return domString(value).toWellFormed();
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

/**
 * The buffer of `value`, a buffer or a view of one, or `undefined` for a value of another type. A resizable buffer
 * throws a `TypeError`.
 */
function bufferOf(value: unknown, name: string): ArrayBufferLike | undefined {
  const buffer = ArrayBuffer.isView(value) ? value.buffer : value;
  if (buffer instanceof ArrayBuffer) {
    if (buffer.resizable) throw new TypeError(`${name} has a resizable buffer`);
    return buffer;
  }
  // The engine makes no growable `SharedArrayBuffer`, so only an `ArrayBuffer` can be resizable.
  return buffer instanceof SharedArrayBuffer ? buffer : undefined;
}

/**
 * The bytes of `value`, a Web IDL `AllowSharedBufferSource`, as a `Uint8Array` over the same memory. A detached buffer
 * gives no bytes. A value of another type, or a resizable buffer, throws a `TypeError`.
 */
export function bytesOf(value: unknown, name: string): Uint8Array {
  const buffer = bufferOf(value, name);
  if (buffer === undefined) throw new TypeError(`${name} is not an ArrayBuffer, a SharedArrayBuffer, or a view of one`);
  if (buffer instanceof ArrayBuffer && buffer.detached) return new Uint8Array(0);
  return ArrayBuffer.isView(value)
    ? new Uint8Array(buffer, value.byteOffset, value.byteLength)
    : new Uint8Array(buffer);
}

/** Check that `value` is a Web IDL `[AllowShared] Uint8Array` whose buffer is not resizable. */
export function checkUint8Array(value: unknown, name: string): asserts value is Uint8Array {
  // A view check too, so an object with only the prototype of a `Uint8Array` fails.
  if (!(ArrayBuffer.isView(value) && value instanceof Uint8Array)) throw new TypeError(`${name} is not a Uint8Array`);
  bufferOf(value, name);
}
