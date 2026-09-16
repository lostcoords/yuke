declare module "yuke:process" {
  interface SpawnOptions {
    /** A relative path resolves against `workspaceRoot`, or the host directory without one. */
    cwd?: string;
    /** Flat key and value pairs that add to or replace the host environment. */
    env?: string[];
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
    exited: Promise<ProcessExit>;
  }

  /** Starts an argument array with no shell in a new process group. */
  export function spawn(argv: string[], options: SpawnOptions | undefined, onOutput: (stream: 1 | 2, text: string) => void, workspaceRoot?: string): NativeProcess;
  /** Resolves after the pipe accepts every byte; rejects above 1 MiB or 1024 queued writes. */
  export function write(id: number, text: string): Promise<void>;
  export function closeStdin(id: number): void;
  /** Sends TERM to the process group, then KILL after a grace period. Answers false when the child already exited. */
  export function kill(id: number): boolean;
}
