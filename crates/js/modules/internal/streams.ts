/**
 * A minimal `ReadableStream` of the Streams Standard: default streams with a default reader and async iteration. It has
 * no byte stream, no BYOB reader, no `tee`, no pipe, and no `ReadableStream.from`. `yuke:internal/web` installs the
 * classes as globals.
 */
import { dictionary, needs, webClass } from "yuke:internal/webidl";

interface StreamState {
  state: "readable" | "closed" | "errored";
  storedError: unknown;
  reader: ReaderState | undefined;
  /** A read or a cancel makes the stream disturbed. */
  disturbed: boolean;
  controller: ControllerState;
}

interface ReadRequest {
  readonly chunk: (chunk: unknown) => void;
  readonly close: () => void;
  readonly error: (error: unknown) => void;
}

interface ReaderState {
  stream: StreamState | undefined;
  readRequests: ReadRequest[];
  closed: PromiseWithResolvers<undefined>;
}

interface ControllerState {
  readonly stream: StreamState;
  queue: { readonly value: unknown; readonly size: number }[];
  queueTotalSize: number;
  started: boolean;
  closeRequested: boolean;
  pulling: boolean;
  pullAgain: boolean;
  readonly highWaterMark: number;
  /** The algorithms of the underlying source. A close or an error clears them, so the source can be collected. */
  size: ((chunk: unknown) => unknown) | undefined;
  pull: (() => Promise<unknown>) | undefined;
  cancel: ((reason: unknown) => Promise<unknown>) | undefined;
}

const streams = new WeakMap<ReadableStream, StreamState>();
const readers = new WeakMap<ReadableStreamDefaultReader, ReaderState>();
const controllers = new WeakMap<ReadableStreamDefaultController, ControllerState>();

/** The key that only this module gives to the `ReadableStreamDefaultController` constructor. */
const CREATE = Symbol("create");

function streamState(value: unknown): StreamState {
  const state = streams.get(value as ReadableStream);
  if (state === undefined) throw new TypeError("the value is not a ReadableStream");
  return state;
}

function readerState(value: unknown): ReaderState {
  const state = readers.get(value as ReadableStreamDefaultReader);
  if (state === undefined) throw new TypeError("the value is not a ReadableStreamDefaultReader");
  return state;
}

function controllerState(value: unknown): ControllerState {
  const state = controllers.get(value as ReadableStreamDefaultController);
  if (state === undefined) throw new TypeError("the value is not a ReadableStreamDefaultController");
  return state;
}

/** A new closed promise of a reader. Its rejection is no fault: the Streams Standard marks it handled. */
function closedPromise(): PromiseWithResolvers<undefined> {
  const closed = Promise.withResolvers<undefined>();
  closed.promise.catch(() => {});
  return closed;
}

/** A method of `source` named `name`, or `undefined`. A value that is not a function throws a `TypeError`. */
function methodOf(
  source: Readonly<Record<string, unknown>>,
  name: string,
): ((...args: unknown[]) => unknown) | undefined {
  const method = source[name];
  if (method === undefined) return undefined;
  if (typeof method !== "function") throw new TypeError(`the ${name} of the underlying source is not a function`);
  return method as (...args: unknown[]) => unknown;
}

export class ReadableStream<R = unknown> {
  constructor(underlyingSource?: unknown, strategy?: unknown) {
    // Web IDL converts the strategy argument first, and it reads the members of a dictionary in the order of their
    // names. The checks of the values come after the conversions.
    const fields = dictionary(strategy, "the strategy");
    const highWaterMark = fields.highWaterMark === undefined ? 1 : +(fields.highWaterMark as number);
    const size = fields.size;
    if (size !== undefined && typeof size !== "function")
      throw new TypeError("the size of the strategy is not a function");
    if ((typeof underlyingSource !== "object" && typeof underlyingSource !== "function") || underlyingSource === null) {
      if (underlyingSource !== undefined) throw new TypeError("the underlying source is not an object");
    }
    const source = dictionary(underlyingSource, "the underlying source");
    const cancel = methodOf(source, "cancel");
    const pull = methodOf(source, "pull");
    const start = methodOf(source, "start");
    if (source.type !== undefined) {
      const type = `${source.type as string}`;
      throw new TypeError(
        type === "bytes" ? "yuke has no byte streams. Leave out the type." : `the stream type '${type}' is not valid`,
      );
    }
    if (Number.isNaN(highWaterMark) || highWaterMark < 0) {
      throw new RangeError("the high water mark is not a number of zero or more");
    }

    const stream: StreamState = {
      state: "readable",
      storedError: undefined,
      reader: undefined,
      disturbed: false,
      controller: undefined as unknown as ControllerState,
    };
    const state: ControllerState = {
      stream,
      queue: [],
      queueTotalSize: 0,
      started: false,
      closeRequested: false,
      pulling: false,
      pullAgain: false,
      highWaterMark,
      size: size as ((chunk: unknown) => unknown) | undefined,
      pull: undefined,
      cancel: undefined,
    };
    stream.controller = state;
    streams.set(this, stream);
    const controller = new ReadableStreamDefaultController(CREATE);
    controllers.set(controller, state);
    state.pull = pull === undefined ? undefined : () => Promise.try(() => pull.call(underlyingSource, controller));
    state.cancel =
      cancel === undefined ? undefined : (reason) => Promise.try(() => cancel.call(underlyingSource, reason));
    const started = start === undefined ? undefined : start.call(underlyingSource, controller);
    Promise.resolve(started).then(
      () => {
        state.started = true;
        callPullIfNeeded(state);
      },
      (error: unknown) => errorController(state, error),
    );
  }

  /** Whether a reader holds the stream. */
  get locked(): boolean {
    return streamState(this).reader !== undefined;
  }

  /** Cancel the stream with `reason`. A locked stream rejects with a `TypeError`. */
  cancel(reason?: unknown): Promise<undefined> {
    let state: StreamState;
    try {
      state = streamState(this);
    } catch (error) {
      return Promise.reject(error);
    }
    if (state.reader !== undefined) return Promise.reject(new TypeError("a reader holds the stream"));
    return cancelStream(state, reason);
  }

  /** A default reader that holds the stream. A `mode` throws a `TypeError`, as yuke has no byte streams. */
  getReader(options?: { readonly mode?: undefined }): ReadableStreamDefaultReader<R> {
    streamState(this);
    const mode = dictionary(options, "the options").mode;
    if (mode !== undefined) {
      const text = `${mode as string}`;
      throw new TypeError(
        text === "byob" ? "yuke has no byte streams, so no BYOB reader" : `the reader mode '${text}' is not valid`,
      );
    }
    return new ReadableStreamDefaultReader<R>(this);
  }

  /**
   * An async iterator of chunks. Iteration holds the stream.
   * An early loop exit cancels the stream unless `preventCancel` is true.
   */
  values(options?: { readonly preventCancel?: boolean | undefined }): ReadableStreamAsyncIterator<R> {
    const preventCancel = Boolean(dictionary(options, "the options").preventCancel);
    // The reader holds the stream at once, so a second consumer fails at its call.
    return chunksOf(new ReadableStreamDefaultReader<R>(this), preventCancel);
  }

  declare [Symbol.asyncIterator]: (options?: {
    readonly preventCancel?: boolean | undefined;
  }) => ReadableStreamAsyncIterator<R>;
}

/** The chunks of `reader`. The end of the iteration releases the stream, and an early exit cancels it first. */
async function* chunksOf<R>(
  reader: ReadableStreamDefaultReader<R>,
  preventCancel: boolean,
): ReadableStreamAsyncIterator<R> {
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) return;
      yield result.value;
    }
  } finally {
    // The standard starts the cancel and then releases the stream, so the release does not wait for the source.
    const cancelled = preventCancel ? undefined : reader.cancel();
    reader.releaseLock();
    await cancelled;
  }
}

export class ReadableStreamDefaultController<R = unknown> {
  /** Only `ReadableStream` makes a controller. */
  constructor(key?: unknown) {
    if (key !== CREATE) throw new TypeError("ReadableStreamDefaultController has no public constructor");
  }

  /** The high water mark less the queued size. It can be negative, it is 0 when closed, and `null` when errored. */
  get desiredSize(): number | null {
    return desiredSize(controllerState(this));
  }

  /** Close the stream after the queued chunks. */
  close(): void {
    const state = controllerState(this);
    if (!canCloseOrEnqueue(state)) throw new TypeError("the stream is closed, errored, or has a close request");
    state.closeRequested = true;
    if (state.queue.length === 0) {
      clearAlgorithms(state);
      closeStream(state.stream);
    }
  }

  /** Give `chunk` to a waiting read, or add it to the queue. */
  enqueue(chunk?: R): void {
    const state = controllerState(this);
    if (!canCloseOrEnqueue(state)) throw new TypeError("the stream is closed, errored, or has a close request");
    const reader = state.stream.reader;
    const request = reader?.readRequests.shift();
    if (request !== undefined) request.chunk(chunk);
    else {
      let size: number;
      try {
        // A plain call gives the size function `undefined` as `this`, as Web IDL calls a callback.
        const measure = state.size;
        size = measure === undefined ? 1 : +(measure(chunk) as number);
        if (!Number.isFinite(size) || size < 0)
          throw new RangeError("the size of a chunk is not a finite number of zero or more");
      } catch (error) {
        errorController(state, error);
        throw error;
      }
      state.queue.push({ value: chunk, size });
      state.queueTotalSize += size;
    }
    callPullIfNeeded(state);
  }

  /** Error the stream with `error`. */
  error(error?: unknown): void {
    errorController(controllerState(this), error);
  }
}

export class ReadableStreamDefaultReader<R = unknown> {
  constructor(...args: [stream: ReadableStream<R>]) {
    needs(args, 1, "ReadableStreamDefaultReader");
    const stream = streamState(args[0]);
    if (stream.reader !== undefined) throw new TypeError("a reader holds the stream");
    const closed = closedPromise();
    const state: ReaderState = { stream, readRequests: [], closed };
    if (stream.state === "closed") closed.resolve(undefined);
    else if (stream.state === "errored") closed.reject(stream.storedError);
    stream.reader = state;
    readers.set(this, state);
  }

  /** A promise that fulfills when the stream closes, and rejects when it errors or the reader releases it. */
  get closed(): Promise<undefined> {
    try {
      return readerState(this).closed.promise;
    } catch (error) {
      return Promise.reject(error);
    }
  }

  /** The next chunk, or `done` after the last chunk. */
  read(): Promise<ReadableStreamReadResult<R>> {
    let state: ReaderState;
    try {
      state = readerState(this);
    } catch (error) {
      return Promise.reject(error);
    }
    const stream = state.stream;
    if (stream === undefined) return Promise.reject(new TypeError("the reader has no stream"));
    const { promise, resolve, reject } = Promise.withResolvers<ReadableStreamReadResult<R>>();
    const request: ReadRequest = {
      chunk: (chunk) => resolve({ done: false, value: chunk as R }),
      close: () => resolve({ done: true, value: undefined }),
      error: reject,
    };
    stream.disturbed = true;
    if (stream.state === "closed") request.close();
    else if (stream.state === "errored") request.error(stream.storedError);
    else pullSteps(stream.controller, state, request);
    return promise;
  }

  /** Release the stream. Each waiting read rejects with a `TypeError`. */
  releaseLock(): void {
    const state = readerState(this);
    const stream = state.stream;
    if (stream === undefined) return;
    const released = new TypeError("the reader released the stream");
    if (stream.state === "readable") state.closed.reject(released);
    else {
      state.closed = closedPromise();
      state.closed.reject(released);
    }
    stream.reader = undefined;
    state.stream = undefined;
    const requests = state.readRequests;
    state.readRequests = [];
    for (const request of requests) request.error(released);
  }

  /** Cancel the stream with `reason`. */
  cancel(reason?: unknown): Promise<undefined> {
    let state: ReaderState;
    try {
      state = readerState(this);
    } catch (error) {
      return Promise.reject(error);
    }
    if (state.stream === undefined) return Promise.reject(new TypeError("the reader has no stream"));
    return cancelStream(state.stream, reason);
  }
}

function desiredSize(state: ControllerState): number | null {
  switch (state.stream.state) {
    case "errored":
      return null;
    case "closed":
      return 0;
    case "readable":
      return state.highWaterMark - state.queueTotalSize;
  }
}

function canCloseOrEnqueue(state: ControllerState): boolean {
  return !state.closeRequested && state.stream.state === "readable";
}

function clearAlgorithms(state: ControllerState): void {
  state.pull = undefined;
  state.cancel = undefined;
  state.size = undefined;
}

function callPullIfNeeded(state: ControllerState): void {
  if (!canCloseOrEnqueue(state) || !state.started) return;
  const waiting = (state.stream.reader?.readRequests.length ?? 0) > 0;
  // The stream is readable here, so the size is the space left in the queue.
  if (!waiting && state.highWaterMark - state.queueTotalSize <= 0) return;
  if (state.pulling) {
    state.pullAgain = true;
    return;
  }
  const pull = state.pull;
  if (pull === undefined) return;
  state.pulling = true;
  pull().then(
    () => {
      state.pulling = false;
      if (state.pullAgain) {
        state.pullAgain = false;
        callPullIfNeeded(state);
      }
    },
    (error: unknown) => errorController(state, error),
  );
}

function errorController(state: ControllerState, error: unknown): void {
  if (state.stream.state !== "readable") return;
  state.queue = [];
  state.queueTotalSize = 0;
  clearAlgorithms(state);
  errorStream(state.stream, error);
}

/** Answer `request` for `reader` from the queue of `state`, or wait for a chunk. */
function pullSteps(state: ControllerState, reader: ReaderState, request: ReadRequest): void {
  const head = state.queue.shift();
  if (head === undefined) {
    reader.readRequests.push(request);
    callPullIfNeeded(state);
    return;
  }
  // The total can drift below zero through floating point rounding, so it stops at zero.
  state.queueTotalSize = Math.max(0, state.queueTotalSize - head.size);
  if (state.closeRequested && state.queue.length === 0) {
    clearAlgorithms(state);
    closeStream(state.stream);
  } else callPullIfNeeded(state);
  request.chunk(head.value);
}

function cancelStream(stream: StreamState, reason: unknown): Promise<undefined> {
  stream.disturbed = true;
  if (stream.state === "closed") return Promise.resolve(undefined);
  if (stream.state === "errored") return Promise.reject(stream.storedError);
  closeStream(stream);
  const controller = stream.controller;
  controller.queue = [];
  controller.queueTotalSize = 0;
  const cancel = controller.cancel;
  clearAlgorithms(controller);
  const cancelled = cancel === undefined ? Promise.resolve() : cancel(reason);
  return cancelled.then(() => undefined);
}

function closeStream(stream: StreamState): void {
  stream.state = "closed";
  const reader = stream.reader;
  if (reader === undefined) return;
  reader.closed.resolve(undefined);
  const requests = reader.readRequests;
  reader.readRequests = [];
  for (const request of requests) request.close();
}

function errorStream(stream: StreamState, error: unknown): void {
  stream.state = "errored";
  stream.storedError = error;
  const reader = stream.reader;
  if (reader === undefined) return;
  reader.closed.reject(error);
  const requests = reader.readRequests;
  reader.readRequests = [];
  for (const request of requests) request.error(error);
}

/** Whether `value` is a `ReadableStream`. */
export function isReadableStream(value: unknown): value is ReadableStream {
  return streams.has(value as ReadableStream);
}

/** Whether a read or a cancel disturbed `stream`. */
export function isDisturbed(stream: ReadableStream): boolean {
  return streamState(stream).disturbed;
}

webClass(ReadableStream, "ReadableStream");
webClass(ReadableStreamDefaultController, "ReadableStreamDefaultController");
webClass(ReadableStreamDefaultReader, "ReadableStreamDefaultReader");
// Web IDL gives the async iterator of an async iterable the function of `values`, and the property is not enumerable.
Object.defineProperty(ReadableStream.prototype, Symbol.asyncIterator, {
  value: ReadableStream.prototype.values,
  writable: true,
  enumerable: false,
  configurable: true,
});
