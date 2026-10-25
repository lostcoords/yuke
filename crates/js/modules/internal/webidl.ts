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

/** The own keys of each class that are not static members. */
const FUNCTION_KEYS: readonly PropertyKey[] = ["length", "name", "prototype"];

/** Give `type` the class string `name`, and make its members and static members enumerable, as Web IDL does. */
export function webClass(type: { readonly prototype: object }, name: string): void {
  for (const key of Reflect.ownKeys(type.prototype)) {
    if (key !== "constructor") Object.defineProperty(type.prototype, key, { enumerable: true });
  }
  for (const key of Reflect.ownKeys(type)) {
    if (!FUNCTION_KEYS.includes(key)) Object.defineProperty(type, key, { enumerable: true });
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

/** Convert `value` as a Web IDL `ByteString`: a symbol or a character above U+00FF throws a `TypeError`. */
export function byteString(value: unknown, name: string): string {
  const text = domString(value);
  // The check of each code unit is the definition of a ByteString.
  for (let index = 0; index < text.length; index++) {
    if (text.charCodeAt(index) > 0xff) throw new TypeError(`${name} has a character above U+00FF`);
  }
  return text;
}

/** The iterator method of `value` bound to `value`, or `undefined` when it has none, as the Web IDL `GetMethod`. */
function iteratorOf(value: object): (() => Iterator<unknown>) | undefined {
  const method: unknown = (value as { [Symbol.iterator]?: unknown })[Symbol.iterator];
  if (method === undefined || method === null) return undefined;
  if (typeof method !== "function") throw new TypeError("the iterator method is not a function");
  return () => method.call(value) as Iterator<unknown>;
}

/**
 * The pairs of `init`, an object that is a Web IDL `sequence<sequence<T>>` or a `record<T, T>`, with `convert` for
 * each name and value. A pair that does not have exactly two values throws a `TypeError`.
 */
export function pairsOf(init: object, convert: (value: unknown) => string): [string, string][] {
  const iterator = iteratorOf(init);
  if (iterator !== undefined) {
    return Array.from({ [Symbol.iterator]: iterator }, (item: unknown): [string, string] => {
      const inner =
        (typeof item === "object" || typeof item === "function") && item !== null ? iteratorOf(item) : undefined;
      if (inner === undefined) throw new TypeError("a pair of the init is not an iterable object");
      const values = Array.from({ [Symbol.iterator]: inner }, (value) => convert(value));
      if (values.length !== 2) throw new TypeError(`a pair of the init has ${values.length} values, not 2`);
      return values as [string, string];
    });
  }
  // Web IDL converts an object to a record: each own enumerable key, in order. A later equal key replaces the value.
  const record = new Map<string, string>();
  for (const key of Reflect.ownKeys(init)) {
    if (Reflect.getOwnPropertyDescriptor(init, key)?.enumerable !== true) continue;
    record.set(convert(key), convert((init as Record<PropertyKey, unknown>)[key]));
  }
  return [...record];
}

type PairKind = "entries" | "keys" | "values";

/**
 * Give `type` the members of a Web IDL pair iterable: `entries`, `keys`, `values`, `forEach`, and the iterator.
 * `pairs` gives the pairs of an object, and it throws a `TypeError` for an object of another class. Each step of an
 * iterator and of `forEach` calls `pairs` again, so it sees each change.
 */
export function pairIterable(
  type: { readonly prototype: object },
  name: string,
  pairs: (target: unknown) => readonly (readonly [string, string])[],
): void {
  const iterators = new WeakMap<object, { readonly target: unknown; readonly kind: PairKind; index: number }>();
  const prototype = Object.create(Iterator.prototype, {
    next: {
      value: {
        next(): IteratorResult<unknown, undefined> {
          const state = iterators.get(this);
          if (state === undefined) throw new TypeError(`the value is not a ${name} iterator`);
          const pair = pairs(state.target)[state.index];
          if (pair === undefined) return { done: true, value: undefined };
          state.index++;
          switch (state.kind) {
            case "entries":
              return { done: false, value: [pair[0], pair[1]] };
            case "keys":
              return { done: false, value: pair[0] };
            case "values":
              return { done: false, value: pair[1] };
          }
        },
      }.next,
      writable: true,
      enumerable: true,
      configurable: true,
    },
    [Symbol.toStringTag]: { value: `${name} Iterator`, configurable: true },
  }) as object;
  const iterate = (target: unknown, kind: PairKind): object => {
    pairs(target);
    const iterator = Object.create(prototype) as object;
    iterators.set(iterator, { target, kind, index: 0 });
    return iterator;
  };
  const members = {
    entries(): object {
      return iterate(this, "entries");
    },
    keys(): object {
      return iterate(this, "keys");
    },
    values(): object {
      return iterate(this, "values");
    },
    forEach(...args: [callback: (value: string, key: string, parent: unknown) => void, thisArg?: unknown]): void {
      pairs(this);
      needs(args, 1, `${name}.forEach`);
      const [callback, thisArg] = args;
      if (typeof callback !== "function") throw new TypeError("the callback is not a function");
      // The callback can change the pairs, so each step reads them again, as Web IDL does.
      for (let index = 0; ; index++) {
        const pair = pairs(this)[index];
        if (pair === undefined) return;
        callback.call(thisArg, pair[1], pair[0], this);
      }
    },
  };
  for (const [key, value] of Object.entries(members)) {
    Object.defineProperty(type.prototype, key, { value, writable: true, enumerable: true, configurable: true });
  }
  // Web IDL gives the iterator the function of `entries`, and the property is not enumerable.
  Object.defineProperty(type.prototype, Symbol.iterator, {
    value: members.entries,
    writable: true,
    configurable: true,
  });
}
