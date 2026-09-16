declare module "yuke:process" {
  interface SpawnOptions {
    /** A relative path resolves against `workspaceRoot`, or the host directory without one. */
    cwd?: string;
    /** Flat key and value pairs that add to or replace the host environment. */
    env?: string[];
    /** Write both streams to a private log instead of pipes. */
    log?: boolean;
  }

  interface ProcessExit {
    /** The exit code, or null after a signal. */
    code: number | null;
    /** The signal number, or null after a normal exit. */
    signal: number | null;
  }

  interface NativeProcess {
    /** Zero when the start failed; `exited` then rejects. */
    id: number;
    /** The log path of a logged child, or null. */
    log: string | null;
    exited: Promise<ProcessExit>;
  }

  /** A string runs through the host shell and an array runs with no shell, in a new process group. */
  export function spawn(command: string | string[], options?: SpawnOptions, onOutput?: (stream: 1 | 2, text: string) => void, workspaceRoot?: string): NativeProcess;
  /** Resolves when the pipe accepts every byte. */
  export function write(id: number, text: string): Promise<void>;
  export function closeStdin(id: number): void;
  /** Sends TERM to the process group, then KILL after a grace period. Answers false when the child already exited. */
  export function kill(id: number): boolean;
}
