/** The connections and the listener of `yuke:net`, which `yuke:test` shares. */

import { addAbortStep } from "yuke:internal/events";
import {
  type NetConnection,
  type NetListener,
  netAccept,
  netClose,
  netListen,
  netRead,
  netUnlisten,
  netWrite,
} from "yuke:internal/native";
import { ReadableStream } from "yuke:internal/streams";
import type { UnixConnection, UnixListener } from "yuke:net";

export class ConnectionError extends Error {
  readonly code: string | undefined;

  constructor(message: string, code: string | undefined) {
    super(message);
    this.code = code;
  }
}
ConnectionError.prototype.name = "ConnectionError";

/**
 * The value that a failed native rejects with: the reason of an aborted signal, a `ConnectionError` of the failure
 * record, or the `ConnectionError` of a closed connection or listener for a stop.
 */
export function failureOf(
  signal: AbortSignal | undefined,
  error: unknown,
  subject: "connection" | "listener" = "connection",
): unknown {
  if (signal?.aborted === true) return signal.reason;
  if (typeof error !== "object" || error === null) return error;
  if ("cancelled" in error) return new ConnectionError(`the ${subject} is closed`, "ERR_CLOSED");
  if ("message" in error) {
    const code = "code" in error && typeof error.code === "string" ? error.code : undefined;
    return new ConnectionError(String(error.message), code);
  }
  return error;
}

export class Connection implements UnixConnection {
  readonly readable: ReadableStream<Uint8Array>;
  readonly #native: NetConnection;
  readonly #signal: AbortSignal | undefined;
  readonly #removeStep: (() => void) | undefined;
  /** The last write in the order of the calls. */
  #writing: Promise<void> = Promise.resolve();
  #controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  /** The stream closed or errored, so the controller takes no more calls. */
  #ended = false;

  constructor(native: NetConnection, signal: AbortSignal | undefined) {
    this.#native = native;
    this.#signal = signal;
    this.readable = new ReadableStream<Uint8Array>(
      {
        start: (controller: ReadableStreamDefaultController<Uint8Array>) => {
          this.#controller = controller;
        },
        pull: async (controller: ReadableStreamDefaultController<Uint8Array>) => {
          let chunk: Uint8Array | undefined;
          try {
            chunk = await this.#run(() => netRead(this.#native));
          } catch (error) {
            // A close or an abort ends the stream itself.
            if (this.#ended) return;
            this.#ended = true;
            throw error;
          }
          // A cancel during the read leaves no stream for the chunk.
          if (this.#ended) return;
          if (chunk !== undefined) controller.enqueue(chunk);
          else {
            this.#ended = true;
            controller.close();
          }
        },
        cancel: () => {
          this.#ended = true;
        },
      },
      // Each read pulls one chunk from the socket, so nothing waits in a queue.
      { highWaterMark: 0 },
    );
    this.#removeStep = signal === undefined ? undefined : addAbortStep(signal, () => this.#end(signal.reason));
  }

  write(bytes: Uint8Array): Promise<void> {
    // The write waits for the writes before it, so it keeps its own copy of the bytes.
    const copy = bytes.slice();
    const written = this.#writing.then(() => this.#run(() => netWrite(this.#native, copy)));
    this.#writing = written.catch(() => undefined);
    return written;
  }

  close(): void {
    this.#end(undefined);
  }

  [Symbol.dispose](): void {
    this.close();
  }

  /** Close the connection. A `reason` errors the stream with it, and no reason ends the stream. A second call does nothing. */
  #end(reason: unknown): void {
    this.#removeStep?.();
    netClose(this.#native);
    if (this.#ended) return;
    this.#ended = true;
    if (reason === undefined) this.#controller?.close();
    else this.#controller?.error(reason);
  }

  /** Await the promise of `start`, and give its failure the shape of this module. */
  async #run<T>(start: () => Promise<T>): Promise<T> {
    try {
      return await start();
    } catch (error) {
      throw failureOf(this.#signal, error);
    }
  }
}

export class Listener implements UnixListener {
  readonly path: string;
  readonly #native: NetListener;
  readonly #signal: AbortSignal | undefined;
  readonly #removeStep: (() => void) | undefined;
  #closed = false;

  constructor(path: string, signal: AbortSignal | undefined) {
    this.path = path;
    this.#signal = signal;
    try {
      this.#native = netListen(path);
    } catch (error) {
      throw failureOf(undefined, error);
    }
    this.#removeStep =
      signal === undefined
        ? undefined
        : addAbortStep(signal, () => {
            try {
              this.#end();
            } catch {
              // A throw stops the other steps of a shared signal, and an abort has no caller for the failure.
            }
          });
  }

  async accept(): Promise<UnixConnection> {
    let native: NetConnection;
    try {
      native = await netAccept(this.#native);
    } catch (error) {
      throw failureOf(this.#signal, error, "listener");
    }
    // A close can come after the native accept and before this check.
    if (this.#closed) {
      netClose(native);
      throw failureOf(this.#signal, { cancelled: true }, "listener");
    }
    return new Connection(native, this.#signal);
  }

  close(): void {
    try {
      this.#end();
    } catch (error) {
      throw failureOf(undefined, error);
    }
  }

  [Symbol.dispose](): void {
    this.close();
  }

  /** Close the listener. A second call does nothing. A failed removal of the socket file throws a failure record. */
  #end(): void {
    this.#closed = true;
    this.#removeStep?.();
    netUnlisten(this.#native);
  }
}
