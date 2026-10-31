/**
 * This module holds `ChatWorking` of `yuke:chat`: the working row of a running turn. The row has a spinner, the phase
 * of the turn, the elapsed time, and the cancel key.
 */

import type { ChatSession, ChatWorkingOptions } from "yuke:chat";
import { argument } from "yuke:internal/chat/tools";
import type { Status, Transcript } from "yuke:transcript";

const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";

const FRAME_MS = 80;

/** The phase of the running turn of `transcript`. A retry gives its countdown to `retryAt`, at the time `now`. */
function phase(transcript: Transcript, now: number, retryAt: number | undefined): string {
  if (transcript.status?.kind === "retry_scheduled" && retryAt !== undefined) {
    return `Retrying in ${Math.max(0, Math.ceil((retryAt - now) / 1000))}s…`;
  }
  const last = transcript.entries.at(-1);
  // A call that ended waits for the next answer of the model.
  if (last?.kind === "tool" && last.status !== "done") {
    const subject = last.hints.subject;
    const value = subject === null ? undefined : argument(last.arguments, subject.argument);
    // A call that the model still writes has no name yet.
    const label = value ?? last.hints.title ?? (last.name === "" ? "a tool call" : last.name);
    return last.status === "streaming" ? `Preparing ${label}…` : `Running ${label}…`;
  }
  if (last?.kind === "reasoning" && last.draft) return "Reasoning…";
  if (last?.kind === "text" && last.draft) return "Responding…";
  return "Waiting…";
}

/** The elapsed time `ms` as `42s` or `3m 05s`. */
function elapsed(ms: number): string {
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
  #status: Status | undefined;

  constructor(chat: ChatSession, options: ChatWorkingOptions) {
    this.#chat = chat;
    this.#now = options.now;
    const stop = chat.onChange(() => this.#sync());
    options.signal.addEventListener("abort", stop, { once: true });
    this.#sync();
  }

  get active(): boolean {
    return this.#start !== undefined;
  }

  get frameMs(): number {
    return FRAME_MS;
  }

  text(cancelKey?: string): { readonly spinner: string; readonly text: string } | undefined {
    const start = this.#start;
    if (start === undefined) return undefined;
    const now = this.#now();
    const spinner = SPINNER[Math.floor((now - start) / FRAME_MS) % SPINNER.length] ?? "";
    const hint = cancelKey === undefined ? "" : ` · ${cancelKey} to interrupt`;
    return { spinner, text: `${phase(this.#chat.transcript, now, this.#retryAt)} (${elapsed(now - start)}${hint})` };
  }

  onChange(listener: () => void): () => void {
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
    const status = transcript.status;
    if (status !== this.#status && status?.kind === "retry_scheduled") this.#retryAt = this.#now() + status.afterMs;
    this.#status = status;
    if (this.active === active) return;
    for (const listener of this.#listeners) listener();
  }
}
