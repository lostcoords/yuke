declare module "yuke:oauth-native" {
  /** Answers `count` secure random bytes (16 to 64) as base64url without padding. */
  export function random(count: number): string;
  /** Answers the SHA-256 of the UTF-8 text as base64url without padding, the PKCE S256 challenge. */
  export function sha256(text: string): string;
  /** Binds a random loopback port for one redirect to `http://127.0.0.1:<port>/callback`. */
  export function listen(): { id: number; port: number };
  /** Answers the request target of the first GET to `/callback`, then closes the listener. The default wait is 300000 ms. */
  export function accept(id: number, options?: { timeoutMs?: number; signal?: import("yuke:cancellation-native").CancellationSignal }): Promise<string>;
  /** Closes a listener that never took its callback; repeat calls are safe. */
  export function close(id: number): void;
  /** Answers the private record for the key, or undefined. */
  export function readRecord(key: string): string | undefined;
  /** Replaces the private record for the key; at most 64 KiB. */
  export function writeRecord(key: string, text: string): void;
  export function removeRecord(key: string): void;
}
