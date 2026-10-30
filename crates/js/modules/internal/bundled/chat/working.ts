/** The working row of a chat pane: a spinner, the phase of the turn, the elapsed time, and the cancel key. */

import { argument } from "yuke:internal/chat/tools";
import type { Transcript } from "yuke:transcript";

const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";

/** The time of one frame of the spinner, in milliseconds. */
export const FRAME_MS = 80;

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

/**
 * The text of the working row at the time `now`, for a turn that started at `started`. `key` is the cancel key, or
 * `undefined` without one.
 */
export function workingText(
  transcript: Transcript,
  started: number,
  now: number,
  retryAt: number | undefined,
  key: string | undefined,
): { readonly spinner: string; readonly text: string } {
  const spinner = SPINNER[Math.floor((now - started) / FRAME_MS) % SPINNER.length] ?? "";
  const hint = key === undefined ? "" : ` · ${key} to interrupt`;
  return { spinner, text: `${phase(transcript, now, retryAt)} (${elapsed(now - started)}${hint})` };
}
