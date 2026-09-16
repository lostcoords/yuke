declare module "yuke:exec" {
  interface ExecOptions {
    /** A relative path resolves against `workspaceRoot`, or the host directory without one. */
    cwd?: string;
    /** The default is 120000 and the maximum is 600000. */
    timeoutMs?: number;
    /** The tool signal cancels this command when its call ends. */
    signal?: { aborted: boolean };
    /** The cap for each stream. The default and the maximum are 65536. */
    maxBytes?: number;
    /** Write both streams to a private log, and keep it when a stream was cut. */
    log?: boolean;
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

  /**
   * Runs one shell line in a fresh shell. Nothing carries to the next call, and stdin is closed.
   * The call ends the whole process group when the shell exits or the deadline passes, so no child outlives the call.
   */
  export function exec(command: string, options?: ExecOptions, workspaceRoot?: string): Promise<ExecResult>;
}
