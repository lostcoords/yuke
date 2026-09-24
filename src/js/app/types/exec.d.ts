declare module "yuke:exec" {
  import type { CancellationSignal } from "yuke:cancellation-native";

  interface ExecOptions {
    /** A relative path resolves against `workspaceRoot`, or the host directory without one. */
    cwd?: string;
    /** The default is 120000 and the maximum is 600000. */
    timeoutMs?: number;
    /** A native signal cancels the command and refuses work after cancellation. */
    signal?: CancellationSignal;
    /** The cap for each stream. The default and the maximum are 65536. */
    maxBytes?: number;
    /** Write both streams to a private log, and keep it when a stream was cut. */
    log?: boolean;
    /** An absolute directory; the host directory without one. */
    workspaceRoot?: string;
    /** Takes the live text of both streams in arrival order, before the result settles. `maxBytes` does not cut it, and it stops after 1 MiB. */
    onOutput?: ((text: string) => void) | undefined;
  }

  interface ExecResult {
    stdout: string;
    stderr: string;
    /** The exit code, or null after a signal or a deadline. */
    code: number | null;
    /** The signal that ended the command, or null. */
    signal: number | null;
    timedOut: boolean;
    /** The bytes the stream dropped between its head and its tail. */
    stdoutDropped: number;
    stderrDropped: number;
    /** The kept log path, or null. The host deletes the log directory when it closes. */
    log: string | null;
  }

  /** Runs one shell line with stdin closed, and ends its process group at shell exit or the deadline. */
  export function exec(command: string, options?: ExecOptions): Promise<ExecResult>;
}
