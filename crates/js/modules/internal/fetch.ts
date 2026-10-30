/**
 * The web classes `Request` and `Response` of the Fetch Standard, their body methods, and `fetch`. A body comes from a
 * string, bytes, or a `URLSearchParams`, and the body of a `Response` also from a `ReadableStream`. yuke has no `Blob`,
 * no `FormData`, and no `clone`. `yuke:internal/web` installs the globals.
 */
import { TextDecoder, TextEncoder } from "yuke:internal/encoding";
import { AbortController, AbortSignal, addAbortStep, signalOf, underSignal } from "yuke:internal/events";
import { Headers, headerList, headersOf, isHeaders, isToken } from "yuke:internal/headers";
import { type HttpBody, type HttpHead, httpClose, httpRead, httpSend } from "yuke:internal/native";
import { isDisturbed, isReadableStream, ReadableStream } from "yuke:internal/streams";
import { queryOf, URL } from "yuke:internal/url";
import { byteString, bytesOf, dictionary, needs, usvString, webClass } from "yuke:internal/webidl";

interface BodyState {
  /** The stream of the body, or `null` for no body. */
  readonly stream: ReadableStream<Uint8Array> | null;
  /** The bytes of a body from a string, bytes, or a `URLSearchParams`, or `null` for a stream body. */
  readonly bytes: Uint8Array | null;
  /** A new `Request` took the body, so the body is used. */
  taken: boolean;
}

/** The body, and the `content-type` that the source of the body gives. */
interface ExtractedBody {
  readonly body: BodyState;
  readonly contentType: string | null;
}

function noBody(): BodyState {
  return { stream: null, bytes: null, taken: false };
}

/** A stream that gives `bytes` as one chunk when they are not empty, and closes. */
function streamOf(bytes: Uint8Array): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller: ReadableStreamDefaultController<Uint8Array>) {
      if (bytes.length > 0) controller.enqueue(bytes);
      controller.close();
    },
  });
}

function byteBody(bytes: Uint8Array, contentType: string | null): ExtractedBody {
  return { body: { stream: streamOf(bytes), bytes, taken: false }, contentType };
}

/** The body of `init`, a Web IDL `BodyInit`. A stream is a body of a `Response` only. */
function extractBody(init: unknown, forRequest: boolean): ExtractedBody {
  if (isReadableStream(init)) {
    if (forRequest) throw new TypeError("yuke sends a request body from a string, bytes, or a URLSearchParams");
    if (init.locked || isDisturbed(init)) throw new TypeError("the body stream is locked or disturbed");
    return { body: { stream: init as ReadableStream<Uint8Array>, bytes: null, taken: false }, contentType: null };
  }
  // The body takes the pairs of the object, so a subclass that changes `toString` has no effect.
  const query = queryOf(init);
  if (query !== undefined) {
    return byteBody(new TextEncoder().encode(query), "application/x-www-form-urlencoded;charset=UTF-8");
  }
  if (ArrayBuffer.isView(init) || init instanceof ArrayBuffer || init instanceof SharedArrayBuffer) {
    // The body keeps a copy, so a later change of the buffer does not change the body.
    return byteBody(new Uint8Array(bytesOf(init, "the body")), null);
  }
  return byteBody(new TextEncoder().encode(usvString(init)), "text/plain;charset=UTF-8");
}

function bodyUsed(body: BodyState): boolean {
  return body.stream !== null && (body.taken || isDisturbed(body.stream));
}

/** All the bytes of `body`. A used or locked body, or a chunk that is no `Uint8Array`, rejects with a `TypeError`. */
async function consume(body: BodyState): Promise<Uint8Array> {
  const stream = body.stream;
  if (stream === null) return new Uint8Array(0);
  if (bodyUsed(body) || stream.locked) throw new TypeError("the body is used or locked");
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const result = await reader.read();
    if (result.done) break;
    const chunk: unknown = result.value;
    if (!(chunk instanceof Uint8Array)) throw new TypeError("a chunk of the body is not a Uint8Array");
    // A source can reuse the buffer of a chunk for the next chunk, so the body keeps a copy.
    chunks.push(new Uint8Array(chunk));
    length += chunk.length;
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

/** Give `type` the members of the Web IDL mixin `Body`. `bodyOf` throws a `TypeError` for a value of another class. */
function includeBody(type: { readonly prototype: object }, bodyOf: (target: unknown) => BodyState): void {
  const members: PropertyDescriptorMap = {
    body: {
      get(this: unknown): ReadableStream<Uint8Array> | null {
        return bodyOf(this).stream;
      },
    },
    bodyUsed: {
      get(this: unknown): boolean {
        return bodyUsed(bodyOf(this));
      },
    },
    arrayBuffer: {
      async value(this: unknown): Promise<ArrayBuffer> {
        return (await consume(bodyOf(this))).buffer as ArrayBuffer;
      },
    },
    bytes: {
      async value(this: unknown): Promise<Uint8Array> {
        return consume(bodyOf(this));
      },
    },
    json: {
      async value(this: unknown): Promise<unknown> {
        return JSON.parse(new TextDecoder().decode(await consume(bodyOf(this))));
      },
    },
    text: {
      async value(this: unknown): Promise<string> {
        return new TextDecoder().decode(await consume(bodyOf(this)));
      },
    },
  };
  for (const [key, descriptor] of Object.entries(members)) {
    const writable = "value" in descriptor ? { writable: true } : {};
    Object.defineProperty(type.prototype, key, { ...descriptor, ...writable, enumerable: true, configurable: true });
  }
}

/** Add the `content-type` of an extracted body when `headers` has none. */
function addContentType(headers: Headers, contentType: string | null): void {
  if (contentType !== null && !headers.has("content-type")) headers.append("content-type", contentType);
}

type Redirect = "follow" | "error" | "manual";

interface RequestState {
  readonly method: string;
  readonly url: string;
  readonly headers: Headers;
  readonly redirect: Redirect;
  readonly signal: AbortSignal;
  readonly body: BodyState;
}

const requests = new WeakMap<Request, RequestState>();

function requestState(value: unknown): RequestState {
  const state = requests.get(value as Request);
  if (state === undefined) throw new TypeError("the value is not a Request");
  return state;
}

/** The methods that the Fetch Standard writes in upper case, whatever case the caller gives. */
const NORMALIZED_METHODS = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"];

/** The methods that the Fetch Standard forbids. */
const FORBIDDEN_METHODS = ["CONNECT", "TRACE", "TRACK"];

function methodOf(value: unknown): string {
  const method = byteString(value, "the method");
  if (!isToken(method)) throw new TypeError(`'${method}' is not a valid method`);
  const upper = method.toUpperCase();
  if (FORBIDDEN_METHODS.includes(upper)) throw new TypeError(`the method ${upper} is forbidden`);
  return NORMALIZED_METHODS.includes(upper) ? upper : method;
}

function redirectOf(value: unknown): Redirect {
  const text = `${value as string}`;
  if (text !== "follow" && text !== "error" && text !== "manual") {
    throw new TypeError(`the redirect '${text}' is not follow, error, or manual`);
  }
  return text;
}

export class Request {
  constructor(...args: [input: string | URL | Request, init?: RequestInit]) {
    needs(args, 1, "Request");
    // Web IDL converts the arguments before the steps: the input, then the members of the init in the order of
    // their names.
    const base = requests.get(args[0] as Request);
    const input = base === undefined ? usvString(args[0]) : undefined;
    const init = dictionary(args[1], "the request init");
    const initBody = init.body;
    const extracted = initBody === undefined || initBody === null ? undefined : extractBody(initBody, true);
    // A `Headers` gives its header list as it is, without the combined values of its iteration.
    const initHeaders =
      init.headers === undefined
        ? undefined
        : isHeaders(init.headers)
          ? headersOf(headerList(init.headers), false)
          : new Headers(init.headers);
    const method = init.method === undefined ? (base?.method ?? "GET") : methodOf(init.method);
    const redirect = init.redirect === undefined ? (base?.redirect ?? "follow") : redirectOf(init.redirect);
    const parent = init.signal === undefined ? base?.signal : init.signal === null ? undefined : signalOf(init.signal);

    let url: string;
    if (input === undefined) url = (base as RequestState).url;
    else {
      const parsed = URL.parse(input);
      if (parsed === null) throw new TypeError(`'${input}' is not a valid URL`);
      if (parsed.username !== "" || parsed.password !== "") {
        throw new TypeError("a request URL cannot hold a user name or a password");
      }
      url = parsed.href;
    }

    const headers = initHeaders ?? (base === undefined ? new Headers() : headersOf(headerList(base.headers), false));
    const baseBody = base?.body;
    if ((extracted !== undefined || baseBody?.stream != null) && (method === "GET" || method === "HEAD")) {
      throw new TypeError(`a ${method} request cannot have a body`);
    }
    let body: BodyState;
    if (extracted !== undefined) {
      addContentType(headers, extracted.contentType);
      body = extracted.body;
    } else if (baseBody !== undefined && baseBody.bytes !== null) {
      if (bodyUsed(baseBody) || baseBody.stream?.locked === true) throw new TypeError("the body is used or locked");
      // The new request takes the body, so the body of the input is used.
      baseBody.taken = true;
      body = byteBody(baseBody.bytes, null).body;
    } else body = noBody();

    // The signal of a request follows the signal of the init or of the input.
    const signal = parent === undefined ? new AbortController().signal : AbortSignal.any([parent]);
    requests.set(this, { method, url, headers, redirect, signal, body });
  }

  get method(): string {
    return requestState(this).method;
  }

  get url(): string {
    return requestState(this).url;
  }

  get headers(): Headers {
    return requestState(this).headers;
  }

  get redirect(): Redirect {
    return requestState(this).redirect;
  }

  get signal(): AbortSignal {
    return requestState(this).signal;
  }

  declare readonly body: ReadableStream<Uint8Array> | null;
  declare readonly bodyUsed: boolean;
  declare arrayBuffer: () => Promise<ArrayBuffer>;
  declare bytes: () => Promise<Uint8Array>;
  declare json: () => Promise<unknown>;
  declare text: () => Promise<string>;
}

interface ResponseState {
  readonly type: ResponseType;
  readonly url: string;
  readonly redirected: boolean;
  readonly status: number;
  readonly statusText: string;
  readonly headers: Headers;
  readonly body: BodyState;
}

const responses = new WeakMap<Response, ResponseState>();

function responseState(value: unknown): ResponseState {
  const state = responses.get(value as Response);
  if (state === undefined) throw new TypeError("the value is not a Response");
  return state;
}

/** The statuses that a response with a body cannot have. */
const NULL_BODY_STATUSES = [101, 103, 204, 205, 304];

/** The statuses of `Response.redirect`. */
const REDIRECT_STATUSES = [301, 302, 303, 307, 308];

/** Convert `value` as a Web IDL `unsigned short`. A value out of range wraps, because it has no `EnforceRange`. */
function unsignedShort(value: unknown): number {
  const number = +(value as number);
  if (!Number.isFinite(number)) return 0;
  return ((Math.trunc(number) % 65_536) + 65_536) % 65_536;
}

/** A new `Response` with `state`, made without the constructor. */
function responseOf(state: ResponseState): Response {
  const response = Object.create(Response.prototype) as Response;
  responses.set(response, state);
  return response;
}

/** The state of a `Response` of `body` and `init`, as the constructor and `Response.json` make it. */
function initialize(body: ExtractedBody | null, init: unknown): ResponseState {
  // Web IDL reads the members of a dictionary in the order of their names.
  const fields = dictionary(init, "the response init");
  const headers = fields.headers === undefined ? new Headers() : new Headers(fields.headers);
  const status = fields.status === undefined ? 200 : unsignedShort(fields.status);
  const statusText = fields.statusText === undefined ? "" : byteString(fields.statusText, "the status text");
  if (status < 200 || status > 599) throw new RangeError(`the status ${status} is not in the range 200 to 599`);
  if (!/^[\t\x20-\x7e\x80-\xff]*$/.test(statusText)) throw new TypeError("the status text is not a reason phrase");
  if (body !== null) {
    if (NULL_BODY_STATUSES.includes(status)) throw new TypeError(`a response with the status ${status} has no body`);
    addContentType(headers, body.contentType);
  }
  return {
    type: "default",
    url: "",
    redirected: false,
    status,
    statusText,
    headers,
    body: body === null ? noBody() : body.body,
  };
}

export class Response {
  constructor(body: unknown = null, init?: ResponseInit) {
    const extracted = body === null ? null : extractBody(body, false);
    responses.set(this, initialize(extracted, init));
  }

  /** A network error: the type `error`, the status 0, and no body. */
  static error(): Response {
    return responseOf({
      type: "error",
      url: "",
      redirected: false,
      status: 0,
      statusText: "",
      headers: headersOf([], true),
      body: noBody(),
    });
  }

  /** A redirect to `url` with `status`, which is 301, 302, 303, 307, or 308. */
  static redirect(...args: [url: string | URL, status?: number]): Response {
    needs(args, 1, "Response.redirect");
    const text = usvString(args[0]);
    const status = args[1] === undefined ? 302 : unsignedShort(args[1]);
    const parsed = URL.parse(text);
    if (parsed === null) throw new TypeError(`'${text}' is not a valid URL`);
    if (!REDIRECT_STATUSES.includes(status)) throw new RangeError(`the status ${status} is not a redirect status`);
    return responseOf({
      type: "default",
      url: "",
      redirected: false,
      status,
      statusText: "",
      headers: headersOf([["location", parsed.href]], true),
      body: noBody(),
    });
  }

  /** A response with the JSON text of `data`. It adds `application/json` when `init` has no `content-type`. */
  static json(...args: [data: unknown, init?: ResponseInit]): Response {
    needs(args, 1, "Response.json");
    const text: string | undefined = JSON.stringify(args[0]);
    if (text === undefined) throw new TypeError("the data has no JSON form");
    return responseOf(initialize(byteBody(new TextEncoder().encode(text), "application/json"), args[1]));
  }

  get type(): ResponseType {
    return responseState(this).type;
  }

  get url(): string {
    return responseState(this).url;
  }

  get redirected(): boolean {
    return responseState(this).redirected;
  }

  get status(): number {
    return responseState(this).status;
  }

  /** Whether the status is in the range 200 to 299. */
  get ok(): boolean {
    const status = responseState(this).status;
    return status >= 200 && status <= 299;
  }

  get statusText(): string {
    return responseState(this).statusText;
  }

  get headers(): Headers {
    return responseState(this).headers;
  }

  declare readonly body: ReadableStream<Uint8Array> | null;
  declare readonly bodyUsed: boolean;
  declare arrayBuffer: () => Promise<ArrayBuffer>;
  declare bytes: () => Promise<Uint8Array>;
  declare json: () => Promise<unknown>;
  declare text: () => Promise<string>;
}

/** The headers that a redirect removes with the body of the request. */
const BODY_HEADERS = ["content-encoding", "content-language", "content-length", "content-location", "content-type"];

/** The most redirects of one fetch, as the Fetch Standard counts them. */
const MOST_REDIRECTS = 20;

/** The `TypeError` of a network failure. The cause names the failure, as in Deno and Node. */
function networkError(message: string, code: string): TypeError {
  return new TypeError("fetch failed", { cause: Object.assign(new Error(message), { code }) });
}

/** The error of a native that rejects: the reason of an aborted signal, or the `TypeError` of the failure record. */
function failureOf(signal: AbortSignal, error: unknown): unknown {
  if (signal.aborted) return signal.reason;
  if (typeof error === "object" && error !== null && "code" in error && "message" in error) {
    return networkError(String(error.message), String(error.code));
  }
  return error;
}

/** `url` without its fragment, as the URL of a response is. */
function withoutFragment(url: string): string {
  const parsed = new URL(url);
  parsed.hash = "";
  return parsed.href;
}

/** The parts of a fetched body that an abort reaches: the native body, the controller, and the read in flight. */
interface BodyWork {
  readonly native: HttpBody;
  controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  stopRead: (() => void) | undefined;
}

/** Remove the abort step of a body that the collector freed, so a long-lived signal keeps no step of it. */
const freedBodies = new FinalizationRegistry<() => void>((remove) => remove());

/**
 * The stream of a fetched body. Each read pulls one chunk from the connection, so nothing waits in a queue. An abort of
 * `signal` stops the read, closes the connection, and errors the stream with the reason. A cancel stops the read and
 * closes the connection.
 */
function bodyStream(native: HttpBody, signal: AbortSignal): ReadableStream<Uint8Array> {
  const work: BodyWork = { native, controller: undefined, stopRead: undefined };
  // The step holds the body weakly, so a signal that outlives an unread response does not keep its connection.
  const weak = new WeakRef(work);
  const remove = addAbortStep(signal, () => {
    const held = weak.deref();
    if (held === undefined) return;
    held.stopRead?.();
    httpClose(held.native);
    held.controller?.error(signal.reason);
  });
  // QuickJS keeps an unregister token alive, so the token is its own object and not the body.
  const token = {};
  freedBodies.register(work, remove, token);
  const end = (): void => {
    freedBodies.unregister(token);
    remove();
  };
  return new ReadableStream<Uint8Array>(
    {
      start(start: ReadableStreamDefaultController<Uint8Array>) {
        work.controller = start;
      },
      async pull(pull: ReadableStreamDefaultController<Uint8Array>) {
        const { promise, cancel } = httpRead(work.native);
        work.stopRead = cancel;
        let chunk: Uint8Array | undefined;
        try {
          chunk = await promise;
        } catch (error) {
          end();
          throw failureOf(signal, error);
        } finally {
          work.stopRead = undefined;
        }
        if (chunk !== undefined) pull.enqueue(chunk);
        else {
          end();
          pull.close();
        }
      },
      cancel() {
        work.stopRead?.();
        end();
        httpClose(work.native);
      },
    },
    { highWaterMark: 0 },
  );
}

/** The response of `head` for the last request of a fetch. */
function fetchedResponse(
  head: HttpHead,
  method: string,
  url: string,
  redirected: boolean,
  signal: AbortSignal,
): Response {
  // A response to `HEAD` and a response with a null body status have no body.
  const empty = method === "HEAD" || NULL_BODY_STATUSES.includes(head.status);
  if (empty) httpClose(head.body);
  return responseOf({
    type: "basic",
    url: withoutFragment(url),
    redirected,
    status: head.status,
    statusText: head.statusText,
    headers: headersOf(head.headers, true),
    body: empty ? noBody() : { stream: bodyStream(head.body, signal), bytes: null, taken: false },
  });
}

/**
 * Fetch `input` with `init`, as `new Request(input, init)` describes it. A network failure rejects with a `TypeError`
 * whose cause names the failure, and an abort rejects with the reason of the signal.
 */
export function fetch(...args: [input: RequestInfo | URL, init?: RequestInit]): Promise<Response> {
  let state: RequestState;
  try {
    needs(args, 1, "fetch");
    state = requestState(new Request(args[0], args[1]));
  } catch (error) {
    return Promise.reject(error);
  }
  return run(state);
}

async function run(state: RequestState): Promise<Response> {
  const signal = state.signal;
  signal.throwIfAborted();
  let { method, url } = state;
  let headers = headerList(state.headers).map(([name, value]): [string, string] => [name, value]);
  let body = state.body.bytes ?? new Uint8Array(0);
  if (!state.headers.has("accept")) headers.push(["accept", "*/*"]);
  // yuke decodes no content encoding, so it asks for none.
  if (!state.headers.has("accept-encoding")) headers.push(["accept-encoding", "identity"]);
  let redirected = false;
  for (let redirects = 0; ; redirects++) {
    let head: HttpHead;
    try {
      // The client sends the path and the query, so the fragment never leaves.
      head = await underSignal(signal, () => httpSend(method, url, headers, body));
    } catch (error) {
      throw failureOf(signal, error);
    }
    if (!REDIRECT_STATUSES.includes(head.status) || state.redirect === "manual") {
      return fetchedResponse(head, method, url, redirected, signal);
    }
    if (state.redirect === "error") {
      httpClose(head.body);
      throw networkError("the server redirected, and the redirect mode is error", "redirect");
    }
    const locations = head.headers.filter((pair) => pair[0] === "location").map((pair) => pair[1]);
    if (locations.length === 0) return fetchedResponse(head, method, url, redirected, signal);
    httpClose(head.body);
    if (locations.length > 1) throw networkError("the server sent more than one location", "redirect");
    const location = locations[0] as string;
    if (redirects === MOST_REDIRECTS) {
      throw networkError(`the server redirected more than ${MOST_REDIRECTS} times`, "redirect");
    }
    const next = URL.parse(location, url);
    if (next === null || (next.protocol !== "http:" && next.protocol !== "https:")) {
      throw networkError(`the redirect location '${location}' is not an http or https URL`, "redirect");
    }
    // A 303 changes each method except GET and HEAD to GET. A 301 or a 302 changes POST to GET. Each change drops the
    // body.
    if (
      (head.status === 303 && method !== "GET" && method !== "HEAD") ||
      ((head.status === 301 || head.status === 302) && method === "POST")
    ) {
      method = "GET";
      body = new Uint8Array(0);
      headers = headers.filter((pair) => !BODY_HEADERS.includes(pair[0].toLowerCase()));
    }
    // A redirect to another origin drops the `authorization` header.
    if (new URL(url).origin !== next.origin) {
      headers = headers.filter((pair) => pair[0].toLowerCase() !== "authorization");
    }
    url = next.href;
    redirected = true;
  }
}

webClass(Request, "Request");
webClass(Response, "Response");
includeBody(Request, (target) => requestState(target).body);
includeBody(Response, (target) => responseState(target).body);
