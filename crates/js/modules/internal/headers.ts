/** The web class `Headers` of the Fetch Standard. `yuke:internal/web` installs it as a global. */
import { byteString, needs, pairIterable, pairsOf, webClass } from "yuke:internal/webidl";

/** A header list: the names keep the case of their first use, and a name can repeat. */
type HeaderList = [name: string, value: string][];

interface HeadersState {
  list: HeaderList;
  /** An immutable object throws a `TypeError` at each change, as the headers of a fetched response. */
  immutable: boolean;
}

const states = new WeakMap<Headers, HeadersState>();

function headersState(value: unknown): HeadersState {
  const state = states.get(value as Headers);
  if (state === undefined) throw new TypeError("the value is not a Headers");
  return state;
}

/** The characters of an HTTP token, which is the form of a header name and a method. */
const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

/** Whether `text` is an HTTP token. */
export function isToken(text: string): boolean {
  return TOKEN.test(text);
}

/** The header name of `value`. A name that is not an HTTP token throws a `TypeError`. */
function headerNameOf(value: unknown): string {
  const name = byteString(value, "the header name");
  if (!isToken(name)) throw new TypeError(`'${name}' is not a valid header name`);
  return name;
}

/**
 * The header value of `value` without its leading and trailing tabs, spaces, and line breaks. A value with a NUL or a
 * line break inside throws a `TypeError`.
 */
function headerValueOf(value: unknown): string {
  const text = byteString(value, "the header value").replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, "");
  if (/[\0\n\r]/.test(text)) throw new TypeError("a header value has a NUL or a line break");
  return text;
}

/** Append a header to `list`. A repeated name takes the case of its first use, as the Fetch Standard says. */
function appendHeader(list: HeaderList, name: string, value: string): void {
  const lower = name.toLowerCase();
  list.push([list.find((pair) => pair[0].toLowerCase() === lower)?.[0] ?? name, value]);
}

function checkMutable(state: HeadersState): void {
  if (state.immutable) throw new TypeError("the headers are immutable");
}

/** The values of `name` in `list`, joined with `, `, or `null` when `list` has no such name. */
function combined(list: HeaderList, name: string): string | null {
  const lower = name.toLowerCase();
  const values = list.filter((pair) => pair[0].toLowerCase() === lower).map((pair) => pair[1]);
  return values.length === 0 ? null : values.join(", ");
}

/**
 * The pairs that `Headers` iterates: the names in lower case and in order, each with its combined value. Each
 * `set-cookie` value stays its own pair.
 */
function sortAndCombine(list: HeaderList): [string, string][] {
  const names = [...new Set(list.map((pair) => pair[0].toLowerCase()))].sort();
  return names.flatMap((name): [string, string][] =>
    name === "set-cookie"
      ? list.filter((pair) => pair[0].toLowerCase() === name).map((pair) => [name, pair[1]])
      : [[name, combined(list, name) as string]],
  );
}

export class Headers {
  /** A `Headers`, a record, or pairs of a name and a value. */
  constructor(init?: unknown) {
    const state: HeadersState = { list: [], immutable: false };
    states.set(this, state);
    if (init === undefined) return;
    if ((typeof init !== "object" && typeof init !== "function") || init === null) {
      throw new TypeError("the headers init is not an object");
    }
    // A `Headers` init is an iterable too, so its pairs come in lower case and combined, as the standard says.
    for (const [name, value] of pairsOf(init, (value) => `${value as string}`)) {
      appendHeader(state.list, headerNameOf(name), headerValueOf(value));
    }
  }

  /** Add a value of `name`. */
  append(...args: [name: string, value: string]): void {
    const state = headersState(this);
    needs(args, 2, "append");
    const name = headerNameOf(args[0]);
    const value = headerValueOf(args[1]);
    checkMutable(state);
    appendHeader(state.list, name, value);
  }

  /** Remove each value of `name`. */
  delete(...args: [name: string]): void {
    const state = headersState(this);
    needs(args, 1, "delete");
    const lower = headerNameOf(args[0]).toLowerCase();
    checkMutable(state);
    state.list = state.list.filter((pair) => pair[0].toLowerCase() !== lower);
  }

  /** The values of `name` joined with `, `, or `null`. */
  get(...args: [name: string]): string | null {
    const state = headersState(this);
    needs(args, 1, "get");
    return combined(state.list, headerNameOf(args[0]));
  }

  /** The values of each `set-cookie` header, in order. */
  getSetCookie(): string[] {
    return headersState(this)
      .list.filter((pair) => pair[0].toLowerCase() === "set-cookie")
      .map((pair) => pair[1]);
  }

  /** Whether a header has `name`. */
  has(...args: [name: string]): boolean {
    const state = headersState(this);
    needs(args, 1, "has");
    const lower = headerNameOf(args[0]).toLowerCase();
    return state.list.some((pair) => pair[0].toLowerCase() === lower);
  }

  /** Give `name` the one value `value`: replace the first value, and remove the others. */
  set(...args: [name: string, value: string]): void {
    const state = headersState(this);
    needs(args, 2, "set");
    const name = headerNameOf(args[0]);
    const value = headerValueOf(args[1]);
    checkMutable(state);
    const lower = name.toLowerCase();
    const first = state.list.findIndex((pair) => pair[0].toLowerCase() === lower);
    const pair = state.list[first];
    if (pair === undefined) {
      state.list.push([name, value]);
      return;
    }
    // The first header keeps the case of its name.
    state.list[first] = [pair[0], value];
    state.list = state.list.filter((pair, index) => index <= first || pair[0].toLowerCase() !== lower);
  }

  declare forEach: (callback: (value: string, name: string, parent: Headers) => void, thisArg?: unknown) => void;
  declare entries: () => HeadersIterator<[string, string]>;
  declare keys: () => HeadersIterator<string>;
  declare values: () => HeadersIterator<string>;
  declare [Symbol.iterator]: () => HeadersIterator<[string, string]>;
}

/** A new `Headers` with the pairs of `list`. An immutable one throws a `TypeError` at each change. */
export function headersOf(list: readonly (readonly [string, string])[], immutable: boolean): Headers {
  const headers = new Headers();
  const state = headersState(headers);
  state.list = list.map(([name, value]) => [name, value]);
  state.immutable = immutable;
  return headers;
}

/** Whether `value` is a `Headers`. */
export function isHeaders(value: unknown): value is Headers {
  return states.has(value as Headers);
}

/** The header list of `headers`, in order and with each repeated name. */
export function headerList(headers: Headers): readonly (readonly [string, string])[] {
  return headersState(headers).list;
}

webClass(Headers, "Headers");
pairIterable(Headers, "Headers", (target) => sortAndCombine(headersState(target).list));
