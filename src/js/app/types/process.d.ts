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
    /** The signal name, for example `SIGTERM`, or null after a normal exit. */
    signal: string | null;
  }

  interface NativeProcess {
    /** Zero when the start failed; `exited` then rejects. */
    id: number;
    exited: Promise<ProcessExit>;
  }

  /** Starts `argv` with no shell in its own process group. `onOutput` receives stream 1 or 2 and text in `Host.pump`. */
  export function spawn(argv: string[], options: SpawnOptions, onOutput: (stream: 1 | 2, text: string) => void, workspaceRoot?: string): NativeProcess;
  /** Resolves when the pipe accepts every byte. Rejects after `closeStdin` or after the child closed its input. */
  export function write(id: number, text: string): Promise<void>;
  /** Closes stdin after every queued write. */
  export function closeStdin(id: number): void;
  /** Ends the process group with TERM, then KILL after a grace period. */
  export function kill(id: number): void;
}
