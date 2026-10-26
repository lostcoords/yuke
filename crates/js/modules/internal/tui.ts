/**
 * The boot module of the terminal interface. A placeholder until the TypeScript core comes: it shows the size, the
 * background class, the last event, the newest notice, and the count of reloads. Ctrl+q quits, ctrl+z suspends, and
 * ctrl+r reloads.
 */
import { type TermEvent, term } from "yuke:internal/term";

const CTRL = 4;
let last = "";
let notice = "";
let reloads = 0;

term.run({
  event(event: TermEvent): void {
    if (event.type === "start" && event.snapshot !== undefined) {
      reloads = (JSON.parse(event.snapshot) as { reloads: number }).reloads;
    }
    if (event.type === "notice") {
      notice = `${event.level} ${event.source}: ${event.text}`;
      return;
    }
    if (event.type === "key" && event.code === "char" && event.mods === CTRL) {
      if (event.char === "q") term.quit();
      if (event.char === "z") term.suspend();
      if (event.char === "r") term.reload(JSON.stringify({ reloads: reloads + 1 }));
    }
    last = JSON.stringify(event);
  },
  draw(): void {
    term.text(0, 0, `yuke ${term.width}x${term.height} ${term.background} reloads ${reloads}`, { bold: true });
    term.text(0, 1, last);
    term.text(0, 2, notice);
    term.text(0, 3, "ctrl+q quits, ctrl+z suspends, ctrl+r reloads", { dim: true });
  },
});
