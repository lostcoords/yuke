/** `spinner` and `SPINNER_INTERVAL` of `yuke:tui`: the mark of work that runs. */

const FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";

export const SPINNER_INTERVAL = 80;

export function spinner(elapsed: number): string {
  return FRAMES[Math.floor(elapsed / SPINNER_INTERVAL) % FRAMES.length] ?? "";
}
