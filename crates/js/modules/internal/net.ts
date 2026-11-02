/** The connections of `yuke:net`, which `yuke:test` shares for its test server. */

import { addAbortStep } from "yuke:internal/events";
import { type NetConnection, netClose, netRead, netWrite, type Operation } from "yuke:internal/native";
import { ReadableStream } from "yuke:internal/streams";
import type { UnixConnection } from "yuke:net";

export class ConnectionError extends Error {
  readonly code: string | undefined;

  constructor(message: string, code: string | undefined) {
    super(message);
    this.code = code;
  }
}
ConnectionError.prototype.name = "ConnectionError";

/** The error of a closed connection. */
function closedError(): ConnectionError {
  return new ConnectionError("the connection is closed", undefined);
}

/**
 * The value that a failed native rejects with: the reason of an aborted signal, a `ConnectionError` of the failure
 * record, or the error of a closed connection for a stop.
 */
export function failureOf(signal: AbortSignal | undefined, error: unknown): unknown {
  if (signal?.aborted === true) return signal.reason;
  if (typeof error !== "object" || error === null) return error;
  if ("cancelled" in error) return closedError();
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
  /** The stops of the open operations. A close calls each one. */
  readonly #stops = new Set<() => void>();
  readonly #removeStep: (() => void) | undefined;
  /** The last write in the order of the calls. */
  #writing: Promise<void> = Promise.resolve();
  #controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  /** The stream closed or errored, so the controller takes no more calls. */
  #ended = false;
  #closed = false;

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

  /** Close the connection once. A `reason` errors the stream with it, and no reason ends the stream. */
  #end(reason: unknown): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#removeStep?.();
    for (const stop of this.#stops) stop();
    netClose(this.#native);
    if (this.#ended) return;
    this.#ended = true;
    if (reason === undefined) this.#controller?.close();
    else this.#controller?.error(reason);
  }

  /** Run the operation of `start` until it ends or the connection closes. */
  async #run<T>(start: () => Operation<T>): Promise<T> {
    if (this.#closed) throw failureOf(this.#signal, { cancelled: true });
    const { promise, cancel } = start();
    this.#stops.add(cancel);
    try {
      return await promise;
    } catch (error) {
      throw failureOf(this.#signal, error);
    } finally {
      this.#stops.delete(cancel);
    }
  }
}
