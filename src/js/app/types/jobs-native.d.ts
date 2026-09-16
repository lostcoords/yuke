declare module "yuke:jobs-native" {
  interface Job {
    id: number;
    /** The session that started the job, or null. */
    sessionId: string | null;
    command: string;
    cwd: string;
    /** The private log that holds both streams without host metadata. */
    log: string;
    state: "running" | "exited" | "failed";
    stopRequested: boolean;
    code: number | null;
    signal: number | null;
    /** Epoch milliseconds. */
    startedAt: number;
    endedAt: number | null;
  }

  /** Starts a shell line as a job; `ended` resolves with the final job. */
  export function start(command: string, sessionId?: string | null, workspaceRoot?: string): Promise<{ job: Job; ended: Promise<Job> }>;
  /** Answers every job, newest first. */
  export function list(): Job[];
  export function get(id: number): Job | null;
  /** Stops a running job and answers it as it is now; the end arrives through `ended`. */
  export function stop(id: number): Job | null;
  /** Reads at most `maxBytes` (4 to 262144) of the job log from `offset`, cut at a character boundary. */
  export function read(id: number, offset: number | null, maxBytes: number): Promise<{ text: string; next: number; size: number; start: number; complete: boolean }>;
}
