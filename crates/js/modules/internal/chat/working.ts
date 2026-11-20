/**
 * This module holds `ChatWorking`: the working row of a running turn. The row has a spinner, the phase
 * of the turn, the elapsed time, and the cancel key.
 */

import type { ChatWorkingOptions, ChatWorkingTextOptions } from "yuke:chat";
import { clipped } from "yuke:internal/chat/rows";
import type { ChatSession } from "yuke:internal/chat/session";
import type { Transcript, TurnFailure } from "yuke:transcript";
import { measure, spinner } from "yuke:tui";

/** How long a tool call waits before the row offers to move it, so a quick call does not flash the hint. */
const BACKGROUND_HINT_MS = 2000;

/** The columns that the phase keeps. A narrower row drops a hint first. */
const SMALLEST_PHASE = 16;

/** The phase of the running turn of `transcript`. A retry gives its countdown to `retryAt`, at the time `now`. */
function phase(transcript: Transcript, now: number, retryAt: number | undefined): string {
  if (transcript.failure?.kind === "retryScheduled" && retryAt !== undefined) {
    return `Retrying in ${Math.max(0, Math.ceil((retryAt - now) / 1000))}s…`;
  }
  const last = transcript.entries.at(-1);
  if (last?.kind === "reasoning" && last.draft) return "Thinking…";
  if (last?.kind === "text" && last.draft) return "Responding…";
  return "Working…";
}

/** The elapsed time `ms` as `42s` or `3m 05s`. */
export function elapsed(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`;
}

/**
 * The activity row of an active turn shows a spinner, a phase label, elapsed time, and a retry countdown.
 * The default label is `Working…`, including during tool calls, without tool names or arguments.
 * The time counts from the first active state that this instance observes with a live handle, not from tool start.
 * Another session or the end of the handle stops the count. This block asks for no frame: while `active`, the owner draws
 * again each `SPINNER_INTERVAL` of `yuke:tui`.
 *
 * ```ts
 * const working = new ChatWorking(chat, { signal: mount.signal, now: () => tui.now() });
 * let stop: (() => void) | undefined;
 * const tick = () => {
 *   stop?.();
 *   stop = working.active && !mount.signal.aborted ? tui.addTimer(SPINNER_INTERVAL, tick) : undefined;
 * };
 * working.addChangeListener(tick);
 * tick();
 * const row = working.text({ cancelKey: "esc" }); // in draw
 * if (row !== undefined) canvas.text(0, 0, `${row.spinner} ${row.text}`);
 * ```
 */
export class ChatWorking {
  readonly #chat: ChatSession;
  readonly #now: () => number;
  readonly #listeners = new Set<() => void>();
  // The start of the running turn and the end of the wait of a scheduled retry, on the clock `now`.
  #start: number | undefined;
  #retryAt: number | undefined;
  // The failure of the transcript at the last change, so a new retry starts its countdown once.
  #failure: TurnFailure | undefined;
  // The first sight of work that a background request moves, on the clock `now`, for the delay of the hint.
  #movableSince: number | undefined;

  constructor(chat: ChatSession, options: ChatWorkingOptions) {
    this.#chat = chat;
    this.#now = options.now;
    const stop = chat.addChangeListener(() => this.#sync());
    options.signal.addEventListener("abort", stop, { once: true });
    this.#sync();
  }

  /** A turn of the shown session runs. */
  get active(): boolean {
    return this.#start !== undefined;
  }

  /** The spinner and the text now, or `undefined` while no turn runs. */
  text(options: ChatWorkingTextOptions = {}): { readonly spinner: string; readonly text: string } | undefined {
    const start = this.#start;
    if (start === undefined) return undefined;
    const now = this.#now();
    const mark = spinner(now - start);
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
    if (width === undefined) return { spinner: mark, text: `${head} ${tail()}` };
    while (hints.length > 0 && measure(tail()) + 1 + SMALLEST_PHASE > width) hints.pop();
    return { spinner: mark, text: `${clipped(head, Math.max(0, width - measure(tail()) - 1))} ${tail()}` };
  }

  /** Call `listener` after each change of `active`. */
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
      // The retry failure of the transcript can outlive its turn, so the next turn shows no old countdown.
      this.#retryAt = undefined;
    }
    const failure = transcript.failure;
    if (failure !== this.#failure && failure?.kind === "retryScheduled") this.#retryAt = this.#now() + failure.afterMs;
    this.#failure = failure;
    if (this.active === active) return;
    for (const listener of this.#listeners) listener();
  }
}
