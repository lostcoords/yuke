/**
 * A minimal `WritableStream` of the Streams Standard: default streams with a default writer. It has no pipe and no
 * transform stream. `yuke:internal/web` installs the classes as globals.
 */
import { dictionary, webClass } from "yuke:internal/webidl";

/** A method of the sink. `call` gives it its arguments. */
type Method = ((...values: never[]) => unknown) | undefined;

interface Sink {
  readonly self: object;
  readonly write: Method;
  readonly close: Method;
  readonly abort: Method;
}

interface Entry {
  readonly chunk: unknown;
  readonly size: number;
  readonly done: PromiseWithResolvers<undefined>;
}

/** A promise whose rejection is no fault: the Streams Standard marks it handled. */
function handled(): PromiseWithResolvers<undefined> {
  const resolvers = Promise.withResolvers<undefined>();
  resolvers.promise.catch(() => {});
  return resolvers;
}

function resolved(): PromiseWithResolvers<undefined> {
  const resolvers = handled();
  resolvers.resolve(undefined);
  return resolvers;
}

function rejected(reason: unknown): PromiseWithResolvers<undefined> {
  const resolvers = handled();
  resolvers.reject(reason);
  return resolvers;
}

/** Call `method` of the sink, and give its result or its throw as a promise. */
function call(sink: Sink, method: Method, ...values: unknown[]): Promise<unknown> {
  if (method === undefined) return Promise.resolve();
  try {
    return Promise.resolve(Reflect.apply(method, sink.self, values));
  } catch (error) {
    return Promise.reject(error);
  }
}

/** The state of one stream. The writer and the controller share it. */
class State {
  state: "writable" | "erroring" | "errored" | "closed" = "writable";
  storedError: unknown;
  writer: WriterState | undefined;
  started = false;
  /** A write or the close of the sink runs. */
  inFlight = false;
  readonly queue: Entry[] = [];
  queueTotalSize = 0;
  closeRequest: PromiseWithResolvers<undefined> | undefined;
  pendingAbort: { readonly reason: unknown; readonly done: PromiseWithResolvers<undefined> } | undefined;
  readonly abortController = new AbortController();
  controller!: WritableStreamDefaultController;
  readonly sink: Sink;
  readonly highWaterMark: number;
  readonly size: (chunk: unknown) => number;

  constructor(sink: Sink, highWaterMark: number, size: (chunk: unknown) => number) {
    this.sink = sink;
    this.highWaterMark = highWaterMark;
    this.size = size;
  }

  get desiredSize(): number | null {
    if (this.state === "errored" || this.state === "erroring") return null;
    if (this.state === "closed") return 0;
    return this.highWaterMark - this.queueTotalSize;
  }

  /** The writer waits while the queue is full and the stream takes writes. */
  updateReady(): void {
    const writer = this.writer;
    if (writer === undefined || this.state !== "writable") return;
    const full = this.closeRequest === undefined && (this.desiredSize ?? 0) <= 0;
    if (full && writer.readySettled) {
      writer.ready = handled();
      writer.readySettled = false;
    } else if (!full && !writer.readySettled) {
      writer.ready.resolve(undefined);
      writer.readySettled = true;
    }
  }

  write(chunk: unknown): Promise<undefined> {
    if (this.state === "errored" || this.state === "erroring") return Promise.reject(this.storedError);
    if (this.state === "closed" || this.closeRequest !== undefined) {
      return Promise.reject(new TypeError("the stream is closing or closed"));
    }
    let size: number;
    try {
      size = this.size(chunk);
      if (!(size >= 0) || size === Infinity) throw new RangeError("the size of the chunk is not a finite number");
    } catch (error) {
      this.startErroring(error);
      return Promise.reject(error);
    }
    const entry: Entry = { chunk, size, done: Promise.withResolvers() };
    this.queue.push(entry);
    this.queueTotalSize += size;
    this.updateReady();
    this.advance();
    return entry.done.promise;
  }

  close(): Promise<undefined> {
    if (this.state === "closed" || this.closeRequest !== undefined) {
      return Promise.reject(new TypeError("the stream is closing or closed"));
    }
    if (this.state === "errored" || this.state === "erroring") return Promise.reject(this.storedError);
    this.closeRequest = Promise.withResolvers();
    this.updateReady();
    this.advance();
    return this.closeRequest.promise;
  }

  abort(reason: unknown): Promise<undefined> {
    if (this.state === "closed" || this.state === "errored") return Promise.resolve(undefined);
    this.abortController.abort(reason);
    if (this.pendingAbort !== undefined) return this.pendingAbort.done.promise;
    const done = Promise.withResolvers<undefined>();
    this.pendingAbort = { reason, done };
    if (this.state === "writable") this.startErroring(reason);
    return done.promise;
  }

  startErroring(reason: unknown): void {
    this.state = "erroring";
    this.storedError = reason;
    const writer = this.writer;
    if (writer !== undefined) {
      if (writer.readySettled) writer.ready = rejected(reason);
      else writer.ready.reject(reason);
      writer.readySettled = true;
    }
    if (!this.inFlight && this.started) this.finishErroring();
  }

  finishErroring(): void {
    this.state = "errored";
    for (const entry of this.queue.splice(0)) entry.done.reject(this.storedError);
    this.queueTotalSize = 0;
    const abort = this.pendingAbort;
    this.pendingAbort = undefined;
    const settle = (): void => {
      this.closeRequest?.reject(this.storedError);
      this.closeRequest = undefined;
      this.writer?.closed.reject(this.storedError);
    };
    if (abort === undefined) {
      settle();
      return;
    }
    call(this.sink, this.sink.abort, abort.reason).then(
      () => {
        abort.done.resolve(undefined);
        settle();
      },
      (error: unknown) => {
        abort.done.reject(error);
        settle();
      },
    );
  }

  /** Run the next write or the close of the sink, one at a time. */
  advance(): void {
    if (!this.started || this.inFlight) return;
    if (this.state === "erroring") {
      this.finishErroring();
      return;
    }
    if (this.state !== "writable") return;
    const entry = this.queue[0];
    if (entry !== undefined) {
      this.inFlight = true;
      call(this.sink, this.sink.write, entry.chunk, this.controller).then(
        () => {
          this.inFlight = false;
          this.queue.shift();
          this.queueTotalSize -= entry.size;
          entry.done.resolve(undefined);
          this.updateReady();
          this.advance();
        },
        (error: unknown) => {
          this.inFlight = false;
          this.queue.shift();
          this.queueTotalSize -= entry.size;
          entry.done.reject(error);
          if (this.state === "writable") this.startErroring(error);
          else this.advance();
        },
      );
      return;
    }
    const close = this.closeRequest;
    if (close === undefined) return;
    this.inFlight = true;
    call(this.sink, this.sink.close).then(
      () => {
        this.inFlight = false;
        this.state = "closed";
        this.closeRequest = undefined;
        // A close that ends wins over an abort that waited for it.
        this.pendingAbort?.done.resolve(undefined);
        this.pendingAbort = undefined;
        close.resolve(undefined);
        this.writer?.closed.resolve(undefined);
      },
      (error: unknown) => {
        this.inFlight = false;
        this.pendingAbort?.done.reject(error);
        this.pendingAbort = undefined;
        this.state = "erroring";
        this.storedError = error;
        this.finishErroring();
      },
    );
  }
}

interface WriterState {
  stream: State | undefined;
  ready: PromiseWithResolvers<undefined>;
  readySettled: boolean;
  closed: PromiseWithResolvers<undefined>;
}

const states = new WeakMap<object, State>();

function stateOf(value: unknown): State {
  const state = states.get(value as object);
  if (state === undefined) throw new TypeError("the value is not a WritableStream");
  return state;
}

export class WritableStream<W = unknown> {
  constructor(underlyingSink?: UnderlyingSink<W>, strategy?: QueuingStrategy<W>) {
    const sink = dictionary(underlyingSink, "the underlying sink");
    if (sink.type !== undefined) throw new RangeError("a writable stream has no type");
    const options = dictionary(strategy, "the strategy");
    const highWaterMark = options.highWaterMark === undefined ? 1 : Number(options.highWaterMark);
    if (Number.isNaN(highWaterMark) || highWaterMark < 0) throw new RangeError("the high water mark is not valid");
    const size = options.size;
    if (size !== undefined && typeof size !== "function") throw new TypeError("the size is not a function");
    const method = (name: string): Method => {
      const value = sink[name];
      if (value === undefined) return undefined;
      if (typeof value !== "function") throw new TypeError(`the ${name} of the sink is not a function`);
      return value as (...values: never[]) => unknown;
    };
    const start = method("start");
    const state = new State(
      { self: sink, write: method("write"), close: method("close"), abort: method("abort") },
      highWaterMark,
      size === undefined ? () => 1 : (chunk) => Number(Reflect.apply(size, undefined, [chunk])),
    );
    states.set(this, state);
    state.controller = Object.create(WritableStreamDefaultController.prototype) as WritableStreamDefaultController;
    controllers.set(state.controller, state);
    const started = start === undefined ? undefined : Reflect.apply(start, sink, [state.controller]);
    Promise.resolve(started).then(
      () => {
        state.started = true;
        state.advance();
      },
      (error: unknown) => {
        state.started = true;
        if (state.state === "writable") state.startErroring(error);
        else state.finishErroring();
      },
    );
  }

  get locked(): boolean {
    return stateOf(this).writer !== undefined;
  }

  abort(reason?: unknown): Promise<undefined> {
    const state = stateOf(this);
    if (state.writer !== undefined) return Promise.reject(new TypeError("the stream is locked"));
    return state.abort(reason);
  }

  close(): Promise<undefined> {
    const state = stateOf(this);
    if (state.writer !== undefined) return Promise.reject(new TypeError("the stream is locked"));
    return state.close();
  }

  getWriter(): WritableStreamDefaultWriter<W> {
    return new WritableStreamDefaultWriter(this);
  }
}

const controllers = new WeakMap<object, State>();

function controllerState(value: unknown): State {
  const state = controllers.get(value as object);
  if (state === undefined) throw new TypeError("the value is not a WritableStreamDefaultController");
  return state;
}

export class WritableStreamDefaultController {
  /** Only `WritableStream` makes a controller, without this constructor. */
  constructor() {
    throw new TypeError("WritableStreamDefaultController has no public constructor");
  }

  /** The signal that aborts at an abort of the stream. */
  get signal(): AbortSignal {
    return controllerState(this).abortController.signal;
  }

  /** Error the stream with `error`. A stream that is not writable stays as it is. */
  error(error?: unknown): void {
    const state = controllerState(this);
    if (state.state === "writable") state.startErroring(error);
  }
}

export class WritableStreamDefaultWriter<W = unknown> {
  readonly #writer: WriterState;

  constructor(stream: WritableStream<W>) {
    const state = stateOf(stream);
    if (state.writer !== undefined) throw new TypeError("the stream is locked");
    const errored = state.state === "errored" || state.state === "erroring";
    this.#writer = {
      stream: state,
      ready: errored ? rejected(state.storedError) : resolved(),
      readySettled: true,
      closed:
        state.state === "closed" ? resolved() : state.state === "errored" ? rejected(state.storedError) : handled(),
    };
    state.writer = this.#writer;
    state.updateReady();
  }

  get closed(): Promise<undefined> {
    return this.#writer.closed.promise;
  }

  get ready(): Promise<undefined> {
    return this.#writer.ready.promise;
  }

  get desiredSize(): number | null {
    const state = this.#writer.stream;
    if (state === undefined) throw new TypeError("the writer released the stream");
    return state.desiredSize;
  }

  write(chunk: W): Promise<undefined> {
    const state = this.#writer.stream;
    if (state === undefined) return Promise.reject(new TypeError("the writer released the stream"));
    return state.write(chunk);
  }

  close(): Promise<undefined> {
    const state = this.#writer.stream;
    if (state === undefined) return Promise.reject(new TypeError("the writer released the stream"));
    return state.close();
  }

  abort(reason?: unknown): Promise<undefined> {
    const state = this.#writer.stream;
    if (state === undefined) return Promise.reject(new TypeError("the writer released the stream"));
    return state.abort(reason);
  }

  releaseLock(): void {
    const writer = this.#writer;
    const state = writer.stream;
    if (state === undefined) return;
    const released = new TypeError("the writer released the stream");
    if (writer.readySettled) writer.ready = rejected(released);
    else writer.ready.reject(released);
    writer.readySettled = true;
    if (state.state === "writable" || state.state === "erroring") writer.closed.reject(released);
    writer.closed = rejected(released);
    writer.stream = undefined;
    state.writer = undefined;
  }
}

webClass(WritableStream, "WritableStream");
webClass(WritableStreamDefaultController, "WritableStreamDefaultController");
webClass(WritableStreamDefaultWriter, "WritableStreamDefaultWriter");
