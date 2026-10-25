/**
 * The boot module of the terminal interface. A placeholder until the TypeScript core comes: it shows the size, the
 * background class, and the last event. Ctrl+q quits and ctrl+z suspends.
 */
import { type TermEvent, term } from "yuke:internal/term";

const CTRL = 4;
let last = "";

term.run({
  event(event: TermEvent): void {
    if (event.type === "key" && event.code === "char" && event.mods === CTRL) {
      if (event.char === "q") term.quit();
      if (event.char === "z") term.suspend();
    }
    last = JSON.stringify(event);
  },
  draw(): void {
    term.text(0, 0, `yuke ${term.width}x${term.height} ${term.background}`, { bold: true });
    term.text(0, 1, last);
    term.text(0, 2, "ctrl+q quits, ctrl+z suspends", { dim: true });
  },
});
