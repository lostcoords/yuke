declare module "yuke:jobs-native" {
  /** The wire job and the private log that holds both streams without host metadata. */
  type Job = Wire.Job & { log: string };

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
