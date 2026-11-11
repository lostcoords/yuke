/**
 * This module holds `ChatWorking` of `yuke:chat`: the working row of a running turn. The row has a spinner, the phase
 * of the turn, the elapsed time, and the cancel key.
 */

import type { ChatSession, ChatWorkingOptions, ChatWorkingTextOptions } from "yuke:chat";
import { clipped } from "yuke:internal/chat/rows";
import type { Transcript, TurnFailure } from "yuke:transcript";
import { measure } from "yuke:tui";

const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";

const FRAME_MS = 80;

/** How long a tool call waits before the row offers to move it, so a quick call does not flash the hint. */
const BACKGROUND_HINT_MS = 2000;

/** The columns that the phase keeps. A narrower row drops a hint first. */
const SMALLEST_PHASE = 16;

/** The phase of the running turn of `transcript`. A retry gives its countdown to `retryAt`, at the time `now`. */
function phase(transcript: Transcript, now: number, retryAt: number | undefined): string {
  if (transcript.failure?.kind === "retry_scheduled" && retryAt !== undefined) {
    return `Retrying in ${Math.max(0, Math.ceil((retryAt - now) / 1000))}s…`;
  }
  const last = transcript.entries.at(-1);
  if (last?.kind === "reasoning" && last.draft) return "Reasoning…";
  if (last?.kind === "text" && last.draft) return "Responding…";
  return "Working…";
}

/** The elapsed time `ms` as `42s` or `3m 05s`. */
export function elapsed(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`;
}

export class ChatWorking {
  readonly #chat: ChatSession;
  readonly #now: () => number;
  readonly #listeners = new Set<() => void>();
  // The start of the running turn and the end of the wait of a scheduled retry, on the clock `now`.
  #start: number | undefined;
  #retryAt: number | undefined;
  // The status of the transcript at the last change, so a new retry starts its countdown once.
  #status: TurnFailure | undefined;
  // The first sight of work that a background request moves, on the clock `now`, for the delay of the hint.
  #movableSince: number | undefined;

  constructor(chat: ChatSession, options: ChatWorkingOptions) {
    this.#chat = chat;
    this.#now = options.now;
    const stop = chat.addChangeListener(() => this.#sync());
    options.signal.addEventListener("abort", stop, { once: true });
    this.#sync();
  }

  get active(): boolean {
    return this.#start !== undefined;
  }

  get frameMs(): number {
    return FRAME_MS;
  }

  text(options: ChatWorkingTextOptions = {}): { readonly spinner: string; readonly text: string } | undefined {
    const start = this.#start;
    if (start === undefined) return undefined;
    const now = this.#now();
    const spinner = SPINNER[Math.floor((now - start) / FRAME_MS) % SPINNER.length] ?? "";
    const movable = this.#chat.handle?.canMoveJobsToBackground() === true;
    if (!movable) this.#movableSince = undefined;
    else this.#movableSince ??= now;
    const hints: string[] = [];
    if (options.cancelKey !== undefined) hints.push(`${options.cancelKey} to interrupt`);
    if (
      options.backgroundKey !== undefined &&
      this.#movableSince !== undefined &&
      now - this.#movableSince >= BACKGROUND_HINT_MS
    ) {
      hints.push(`${options.backgroundKey} to background`);
    }
    const tail = (): string => `(${[elapsed(now - start), ...hints].join(" · ")})`;
    const head = phase(this.#chat.transcript, now, this.#retryAt);
    const width = options.width;
    if (width === undefined) return { spinner, text: `${head} ${tail()}` };
    while (hints.length > 0 && measure(tail()) + 1 + SMALLEST_PHASE > width) hints.pop();
    return { spinner, text: `${clipped(head, Math.max(0, width - measure(tail()) - 1))} ${tail()}` };
  }

  addChangeListener(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  /** Count from the first running state of a handle, and count a new retry down from its event. */
  #sync(): void {
    const chat = this.#chat;
    const transcript = chat.transcript;
    const active = this.active;
    // An ended handle gets no more events, so its last state does not count. An open shows its snapshot without a
    // handle, so another session starts its own count.
    const running = chat.handle !== undefined && transcript.state === "running";
    if (running) this.#start ??= this.#now();
    else {
      this.#start = undefined;
      // The retry status of the transcript can outlive its turn, so the next turn shows no old countdown.
      this.#retryAt = undefined;
    }
    const status = transcript.failure;
    if (status !== this.#status && status?.kind === "retry_scheduled") this.#retryAt = this.#now() + status.afterMs;
    this.#status = status;
    if (this.active === active) return;
    for (const listener of this.#listeners) listener();
  }
}
