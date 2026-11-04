// The declaration of the public module `yuke:net`.

/**
 * Connections to Unix sockets and listeners on them.
 * - The `signal` of `connect` covers the connect, each write, and each read.
 * - The `signal` of `listen` covers each accept and each accepted connection.
 * - An abort closes the connection. Each open operation then rejects with the reason of the signal.
 * - The close of the runtime closes each open connection and listener after the cleanups of the plugins.
 * - yuke sets no limit on the time or on the bytes.
 * - A relative `path` throws a `TypeError`.
 */
declare module "yuke:net" {
  /** The options of `connect`. */
  export interface ConnectOptions {
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

  /** The failure of a connection or a listener. */
  export class ConnectionError extends Error {
    constructor(message: string, code: string | undefined);
    /**
     * The POSIX name of the failure: `ENOENT` (no socket or folder at the path), `ECONNREFUSED` (no server at the
     * path), `EADDRINUSE` (the path exists), `EACCES`, `EPIPE`, or `ECONNRESET`.
     * A closed connection and a closed listener have `ERR_CLOSED`. Another failure has `undefined`.
     */
    readonly code: string | undefined;
  }

  /** Connect to the socket at `options.path`. A failure rejects with a `ConnectionError`. */
  export function connect(options: ConnectOptions): Promise<UnixConnection>;

  /** The options of `listen`. */
  export interface ListenOptions {
    /** The absolute path of the socket. */
    path: string;
    /** A signal that closes the listener and each accepted connection. Each open operation rejects with its reason. */
    signal?: AbortSignal | undefined;
  }

  /** A listener on a Unix socket. `using` closes it. */
  export interface UnixListener extends Disposable {
    /** The absolute path of the socket. */
    readonly path: string;
    /**
     * The next connection. Several calls can wait at once. A close rejects each pending and later call with `ERR_CLOSED`.
     * A failed call leaves the listener open.
     */
    accept: () => Promise<UnixConnection>;
    /**
     * Close the listener and remove its socket file. Accepted connections stay open. A client loses its connection when
     * no `accept` gets it. A second close does nothing. A failed removal throws a `ConnectionError`, and the
     * caller removes the file.
     */
    close: () => void;
  }

  /**
   * Listen at `options.path`. A failure throws a `ConnectionError`.
   * - An existing path stays as it is, and the call fails with `EADDRINUSE`. A crash leaves its socket file: `connect`
   *   then fails with `ECONNREFUSED`, and the caller can remove the file.
   * - A reload loads the new plugins before the old plugins close, so a plugin takes a new path for each runtime.
   * - The umask sets the mode of the socket file, so the folder of the path controls who can connect.
   */
  export function listen(options: ListenOptions): UnixListener;
}
