declare module "yuke:net-native" {
  export interface Options {
    /** Cancellation or timeout closes the connection and interrupts its other operation. */
    signal?: import("yuke:cancellation-native").CancellationSignal;
    /** The total operation deadline in milliseconds; default 5000, maximum 600000. */
    timeoutMs?: number;
  }
  export interface ConnectOptions extends Options {
    /** A filesystem Unix socket path; abstract addresses are not supported. */
    path: string;
  }
  export interface ReadOptions extends Options {
    /** The largest returned chunk; default 65536, maximum 1048576 bytes. */
    maxBytes?: number;
  }
  export interface Socket {
    /** Return a byte chunk or null at EOF; a concurrent read rejects with code BUSY. */
    read(options?: ReadOptions): Promise<Uint8Array | null>;
    /** Copy and send the whole chunk, up to 1048576 bytes; a concurrent write rejects with code BUSY. */
    write(bytes: Uint8Array, options?: Options): Promise<void>;
    /** Request closure without a wait; repeat calls are safe. */
    close(): void;
  }
  /** The host permits at most 64 live connections, including pending connects and closes. */
  export function connect(options: ConnectOptions): Promise<number>;
  /** One read may run with one write; another read rejects with code BUSY. */
  export function read(id: number, options?: ReadOptions): Promise<Uint8Array | null>;
  /** Copy and send the whole chunk, up to 1048576 bytes; another write rejects with code BUSY. */
  export function write(id: number, bytes: Uint8Array, options?: Options): Promise<void>;
  /** Close is idempotent; native tasks drain before the descriptor is released. */
  export function close(id: number): void;
}
