declare module "yuke:internal/native/http" {
  import type { CancellationSignal } from "yuke:internal/native/cancellation";

  export interface FetchOptions {
    method?: "GET" | "POST" | "PUT" | "PATCH" | "HEAD" | "DELETE";
    headers?: Record<string, string>;
    body?: string;
    /** The connect and head deadline; default 30000, maximum 600000. */
    timeoutMs?: number;
    signal?: CancellationSignal;
  }

  export interface ReadOptions {
    /** The deadline of one read; default 30000, maximum 600000. */
    timeoutMs?: number;
    signal?: CancellationSignal;
    /** The largest chunk one read answers; default 65536, from 4 to 1048576. */
    maxBytes?: number;
  }

  export interface HttpHead {
    /** A 3xx status answers the head alone; the caller reads `location` and decides whether to follow it. */
    status: number;
    /** The parked body, or zero when the response has none. */
    body: number;
    /** Lowercase names. A repeated field joins its values with ", ". */
    headers: Record<string, string>;
  }

  /** Resolves at the response head. The body waits for reads. */
  export function fetch(url: string, options?: FetchOptions): Promise<HttpHead>;
  /** Answers one text chunk cut on a character boundary, or null at the end. A concurrent read rejects. */
  export function read(id: number, options?: ReadOptions): Promise<string | null>;
  /** Answers the rest of the body as text, or rejects above 256 KiB. */
  export function readAll(id: number, options?: ReadOptions): Promise<string>;
  /** Drops the body and its connection; repeat calls are safe. */
  export function close(id: number): void;
}
