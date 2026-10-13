// The native modules: Rust functions for the built-in modules (crates/js/src/native).

declare module "yuke:internal/native/tools" {
  /** The start of a call: the promise of its answer, and the function that aborts its signal. */
  export interface Started {
    readonly answer: Promise<unknown>;
    readonly abort: (reason: unknown) => void;
  }

  /** Add a tool to the registry of the runtime. A second tool with the same name throws a `TypeError`. */
  export function register(
    name: string,
    description: string,
    parameters: string,
    concurrency: "serial" | "parallel",
    start: (argumentsText: string, callId: string, folder: string, output: (text: string) => void) => Started,
  ): void;
}

declare module "yuke:internal/native/fs" {
  /** Numbered lines, or an image. */
  export type Lines =
    | {
        /** Each line as `N: text` and a line feed. */
        readonly text: string;
        /** The first line that the read left out. */
        readonly next: number | undefined;
        /** A line that the read cut, because it alone is longer than the limit. */
        readonly cut: number | undefined;
      }
    | { readonly image: { readonly path: string; readonly mime: string } };

  /** At most `limit` lines from line `offset`, while they fit in `maxBytes`. */
  export function readLines(
    path: string,
    folder: string,
    offset: number,
    limit: number,
    maxBytes: number,
  ): Promise<Lines>;
  /** The whole file as text. */
  export function readText(path: string, folder: string): Promise<string>;
  /** Write the file and make its missing parent folders. Answers the byte count. */
  export function writeText(path: string, folder: string, text: string): Promise<number>;
}
