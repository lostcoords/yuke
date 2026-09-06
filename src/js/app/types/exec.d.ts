declare module "yuke:exec" {
  interface ExecOptions {
    /** A relative path resolves against the directory the host runs in. */
    cwd?: string;
    /** The default is 120000 and the maximum is 600000. */
    timeoutMs?: number;
    /** The tool signal cancels this command when its call ends. */
    signal?: { aborted: boolean };
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
  }

  /**
   * Runs one shell line in a fresh shell. Nothing carries to the next call, and stdin is closed.
   * A deadline stops the whole process group, so a background child does not outlive the call.
   */
  export function exec(command: string, options?: ExecOptions, workspaceRoot?: string): Promise<ExecResult>;
}
