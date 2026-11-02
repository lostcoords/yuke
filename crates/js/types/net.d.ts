// The declaration of the public module `yuke:net`.

/**
 * Connections to Unix sockets, in the shape of `Deno.connect`.
 * - The `signal` of `connect` covers the connect, each write, and each read.
 * - An abort closes the connection. Each open operation then rejects with the reason of the signal.
 * - The close of the runtime closes each open connection after the cleanups of the plugins.
 * - yuke sets no limit on the time or on the bytes.
 * - A relative `path` throws a `TypeError`.
 */
declare module "yuke:net" {
  /** The options of `connect`. */
  export interface ConnectOptions {
    /** The kind of socket. Only `"unix"` exists. */
    transport: "unix";
    /** The absolute path of the socket. */
    path: string;
    /** A signal that closes the connection. */
    signal?: AbortSignal | undefined;
  }

  /** A connection to a Unix socket. `using` closes it. */
  export interface UnixConnection extends Disposable {
    /**
     * The bytes from the peer, in chunks. The stream ends at the end of the peer or at a close.
     * An abort errors the stream with the reason. A cancel of the stream keeps the connection open.
     */
    readonly readable: ReadableStream<Uint8Array>;
    /** Write each byte of `bytes`. The writes run in the order of the calls. */
    write: (bytes: Uint8Array) => Promise<void>;
    /** Close the connection. An open write rejects, and the stream ends. A second close does nothing. */
    close: () => void;
  }

  /** The failure of a connection. */
  export class ConnectionError extends Error {
    constructor(message: string, code: string | undefined);
    /**
     * The POSIX name of the failure: `ENOENT` (no socket at the path), `ECONNREFUSED` (no server at the path),
     * `EACCES`, `EPIPE`, or `ECONNRESET`. Another failure and a closed connection have `undefined`.
     */
    readonly code: string | undefined;
  }

  /** Connect to the socket at `options.path`. A failure rejects with a `ConnectionError`. */
  export function connect(options: ConnectOptions): Promise<UnixConnection>;
}
