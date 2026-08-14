// Shared host module types. Keep in sync with fs.odin, exec.odin, and diff_module.odin.

declare module "yuke:fs" {
  export interface FsStat {
    name: string;
    /** Absolute, after `~` expansion and base resolution. */
    path: string;
    size: number;
    isDirectory: boolean;
    isFile: boolean;
  }

  // A leading `~` expands, and a relative path resolves against the host's base. A host with
  // no base rejects relative paths, so a path there is always absolute.
  export function readFile(path: string): Promise<string>;

  /** Writes the whole file, making parent directories. Resolves the byte count. */
  export function writeFile(path: string, contents: string): Promise<number>;

  /**
   * Replaces `oldText` with `newText`, resolving the replacement count. Rejects when
   * `oldText` is absent, or when it appears more than once and `replaceAll` is not set.
   */
  export function edit(path: string, oldText: string, newText: string, replaceAll?: boolean): Promise<number>;

  export function readDir(path: string): Promise<FsStat[]>;

  export function stat(path: string): Promise<FsStat>;

  export function exists(path: string): Promise<boolean>;

  /** Hex sha256 of the file, or `null` when it does not exist. */
  export function hash(path: string): Promise<string | null>;
}

declare module "yuke:exec" {
  export interface ExecOptions {
    cwd?: string;
    /** Default 120000, capped at 600000. */
    timeoutMs?: number;
  }

  export interface ExecResult {
    stdout: string;
    stderr: string;
    code: number;
    timedOut: boolean;
    /** A stream reached its 1 MiB cap, so the text above is not the whole output. */
    truncated: boolean;
  }

  /**
   * Runs one shell line in a fresh shell. Nothing is carried between calls. On a timeout the
   * whole process tree is signalled, so a backgrounded child does not outlive the call.
   * Not available on Windows yet, where the call throws.
   */
  export function exec(command: string, options?: ExecOptions): Promise<ExecResult>;
}

declare module "yuke:diff" {
  export interface DiffHunk {
    oldStart: number;
    oldLines: number;
    newStart: number;
    newLines: number;
    /** Unified-diff body lines, each prefixed with a space, `-`, or `+`. */
    lines: string[];
  }

  export interface DiffFile {
    path: string;
    hunks: DiffHunk[];
  }

  /** `path` only labels the result. Rejects when the change is too large to describe. */
  export function diff(path: string, before: string, after: string): Promise<DiffFile>;
}
