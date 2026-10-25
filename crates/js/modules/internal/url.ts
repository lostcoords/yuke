/**
 * The web classes `URL` and `URLSearchParams` on the WHATWG URL parser of the Rust `url` crate. `yuke:internal/web`
 * installs them as globals.
 */
import {
  parseQuery,
  parseUrl,
  serializeQuery,
  type UrlComponent,
  type UrlParts,
  updateUrl,
} from "yuke:internal/native";
import { needs, pairIterable, pairsOf, usvString, webClass } from "yuke:internal/webidl";

type Pair = [name: string, value: string];

interface UrlState {
  parts: UrlParts;
  /** The object of `searchParams`, made at its first read. */
  query: URLSearchParams | undefined;
}

interface QueryState {
  list: Pair[];
  /** The URL whose query the list holds. A change of the list sets the query of the URL. */
  url: URL | undefined;
}

const urls = new WeakMap<URL, UrlState>();
const queries = new WeakMap<URLSearchParams, QueryState>();

function urlState(value: unknown): UrlState {
  const state = urls.get(value as URL);
  if (state === undefined) throw new TypeError("the value is not a URL");
  return state;
}

function queryState(value: unknown): QueryState {
  const state = queries.get(value as URLSearchParams);
  if (state === undefined) throw new TypeError("the value is not a URLSearchParams");
  return state;
}

/** The parts of the URL of `args`, a URL and an optional base, or `undefined` when either one is not valid. */
function parse(args: readonly unknown[]): UrlParts | undefined {
  const input = usvString(args[0]);
  return parseUrl(input, args[1] === undefined ? undefined : usvString(args[1]));
}

/** A new `URL` with `parts`. It skips the constructor, so the URL is not parsed twice. */
function urlOf(parts: UrlParts): URL {
  const url = Object.create(URL.prototype) as URL;
  urls.set(url, { parts, query: undefined });
  return url;
}

/** Run the setter of `component` with `value`. A refused value keeps the URL, as the URL Standard says. */
function setComponent(url: unknown, component: UrlComponent, value: unknown): UrlState {
  const state = urlState(url);
  const parts = updateUrl(state.parts.href, component, usvString(value));
  if (parts !== undefined) state.parts = parts;
  return state;
}

/** Give the object of `searchParams` the pairs of the new query of the URL. */
function refreshQuery(state: UrlState): void {
  if (state.query !== undefined) queryState(state.query).list = parseQuery(state.parts.search.slice(1));
}

/** Set the query of the URL of `state` to its list. An empty list removes the query. */
function updateQuery(state: QueryState): void {
  if (state.url === undefined) return;
  const url = urlState(state.url);
  const parts = updateUrl(url.parts.href, "search", serializeQuery(state.list));
  if (parts !== undefined) url.parts = parts;
}

export class URL {
  constructor(...args: [url: string | URL, base?: string | URL]) {
    needs(args, 1, "URL");
    const input = usvString(args[0]);
    const base = args[1] === undefined ? undefined : usvString(args[1]);
    const parts = parseUrl(input, base);
    if (parts === undefined) {
      throw new TypeError(
        base === undefined ? `'${input}' is not a valid URL` : `'${input}' with the base '${base}' is not a valid URL`,
      );
    }
    urls.set(this, { parts, query: undefined });
  }

  /** The URL of `url` against `base`, or `null` when either one is not valid. */
  static parse(...args: [url: string | URL, base?: string | URL]): URL | null {
    needs(args, 1, "URL.parse");
    const parts = parse(args);
    return parts === undefined ? null : urlOf(parts);
  }

  /** Whether `url` against `base` is a valid URL. */
  static canParse(...args: [url: string | URL, base?: string | URL]): boolean {
    needs(args, 1, "URL.canParse");
    return parse(args) !== undefined;
  }

  get href(): string {
    return urlState(this).parts.href;
  }

  set href(value: string) {
    const state = urlState(this);
    const input = usvString(value);
    const parts = parseUrl(input, undefined);
    if (parts === undefined) throw new TypeError(`'${input}' is not a valid URL`);
    state.parts = parts;
    refreshQuery(state);
  }

  get origin(): string {
    return urlState(this).parts.origin;
  }

  get protocol(): string {
    return urlState(this).parts.protocol;
  }

  set protocol(value: string) {
    setComponent(this, "protocol", value);
  }

  get username(): string {
    return urlState(this).parts.username;
  }

  set username(value: string) {
    setComponent(this, "username", value);
  }

  get password(): string {
    return urlState(this).parts.password;
  }

  set password(value: string) {
    setComponent(this, "password", value);
  }

  get host(): string {
    return urlState(this).parts.host;
  }

  set host(value: string) {
    setComponent(this, "host", value);
  }

  get hostname(): string {
    return urlState(this).parts.hostname;
  }

  set hostname(value: string) {
    setComponent(this, "hostname", value);
  }

  get port(): string {
    return urlState(this).parts.port;
  }

  set port(value: string) {
    setComponent(this, "port", value);
  }

  get pathname(): string {
    return urlState(this).parts.pathname;
  }

  set pathname(value: string) {
    setComponent(this, "pathname", value);
  }

  get search(): string {
    return urlState(this).parts.search;
  }

  set search(value: string) {
    refreshQuery(setComponent(this, "search", value));
  }

  get searchParams(): URLSearchParams {
    const state = urlState(this);
    if (state.query === undefined) {
      const query = new URLSearchParams(state.parts.search);
      queryState(query).url = this;
      state.query = query;
    }
    return state.query;
  }

  get hash(): string {
    return urlState(this).parts.hash;
  }

  set hash(value: string) {
    setComponent(this, "hash", value);
  }

  toString(): string {
    return urlState(this).parts.href;
  }

  toJSON(): string {
    return urlState(this).parts.href;
  }
}

export class URLSearchParams {
  constructor(init: unknown = "") {
    queries.set(this, { list: initPairs(init), url: undefined });
  }

  /** The count of pairs. */
  get size(): number {
    return queryState(this).list.length;
  }

  /** Add a pair at the end. */
  append(...args: [name: string, value: string]): void {
    const state = queryState(this);
    needs(args, 2, "append");
    state.list.push([usvString(args[0]), usvString(args[1])]);
    updateQuery(state);
  }

  /** Remove each pair with `name`, and with `value` when it is given. */
  delete(...args: [name: string, value?: string]): void {
    const state = queryState(this);
    needs(args, 1, "delete");
    const name = usvString(args[0]);
    const value = args[1] === undefined ? undefined : usvString(args[1]);
    state.list = state.list.filter((pair) => pair[0] !== name || (value !== undefined && pair[1] !== value));
    updateQuery(state);
  }

  /** The value of the first pair with `name`, or `null`. */
  get(...args: [name: string]): string | null {
    const state = queryState(this);
    needs(args, 1, "get");
    const name = usvString(args[0]);
    return state.list.find((pair) => pair[0] === name)?.[1] ?? null;
  }

  /** The values of the pairs with `name`, in order. */
  getAll(...args: [name: string]): string[] {
    const state = queryState(this);
    needs(args, 1, "getAll");
    const name = usvString(args[0]);
    return state.list.filter((pair) => pair[0] === name).map((pair) => pair[1]);
  }

  /** Whether a pair has `name`, and `value` when it is given. */
  has(...args: [name: string, value?: string]): boolean {
    const state = queryState(this);
    needs(args, 1, "has");
    const name = usvString(args[0]);
    const value = args[1] === undefined ? undefined : usvString(args[1]);
    return state.list.some((pair) => pair[0] === name && (value === undefined || pair[1] === value));
  }

  /**
   * Give the first pair with `name` the value `value`, and remove the other pairs with `name`. Without a pair with
   * `name`, add a pair at the end.
   */
  set(...args: [name: string, value: string]): void {
    const state = queryState(this);
    needs(args, 2, "set");
    const name = usvString(args[0]);
    const value = usvString(args[1]);
    const first = state.list.findIndex((pair) => pair[0] === name);
    if (first < 0) state.list.push([name, value]);
    else {
      state.list[first] = [name, value];
      state.list = state.list.filter((pair, index) => index <= first || pair[0] !== name);
    }
    updateQuery(state);
  }

  /** Sort the pairs by name in UTF-16 code unit order. Pairs with equal names keep their order. */
  sort(): void {
    const state = queryState(this);
    state.list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    updateQuery(state);
  }

  /** The `application/x-www-form-urlencoded` string of the pairs, without a `?`. */
  toString(): string {
    return serializeQuery(queryState(this).list);
  }

  declare forEach: (
    callback: (value: string, name: string, parent: URLSearchParams) => void,
    thisArg?: unknown,
  ) => void;
  declare entries: () => URLSearchParamsIterator<[string, string]>;
  declare keys: () => URLSearchParamsIterator<string>;
  declare values: () => URLSearchParamsIterator<string>;
  declare [Symbol.iterator]: () => URLSearchParamsIterator<[string, string]>;
}

/** The pairs of `init`: pairs of an iterable, the properties of an object, or a query string with an optional `?`. */
function initPairs(init: unknown): Pair[] {
  if ((typeof init === "object" || typeof init === "function") && init !== null) return pairsOf(init, usvString);
  const text = usvString(init);
  return parseQuery(text.startsWith("?") ? text.slice(1) : text);
}

/** The `application/x-www-form-urlencoded` string of `value` when it is a `URLSearchParams`, or `undefined`. */
export function queryOf(value: unknown): string | undefined {
  const state = queries.get(value as URLSearchParams);
  return state === undefined ? undefined : serializeQuery(state.list);
}

webClass(URL, "URL");
webClass(URLSearchParams, "URLSearchParams");
pairIterable(URLSearchParams, "URLSearchParams", (target) => queryState(target).list);
