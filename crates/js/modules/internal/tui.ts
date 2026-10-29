/** The boot of the terminal interface: the core on the terminal and the keys of the core commands. */
import { type TermEvent, term } from "yuke:internal/term";
import { CORE, Core } from "yuke:internal/tui/core";
import { setSurfaces } from "yuke:internal/tui/host";
import { createSurface } from "yuke:internal/tui/surface";

const LEADER = "ctrl+k";

const core = new Core({
  width: () => term.width,
  height: () => term.height,
  background: () => term.background,
  truecolor: () => term.truecolor,
  text: (column, row, text, style) => {
    term.text(column, row, text, style);
  },
  fill: (column, row, width, height, style) => term.fill(column, row, width, height, style),
  cursor: (cursor) => term.cursor(cursor),
  requestFrame: (delay) => term.requestFrame(delay),
  copy: (text) => term.copy(text),
  quit: () => term.quit(),
  suspend: () => term.suspend(),
  reload: (snapshot) => term.reload(snapshot),
});

const bindings: readonly (readonly [string, string])[] = [
  ["ctrl+q", "quit"],
  ["ctrl+z", "suspend"],
  [`${LEADER} v`, "split-right"],
  [`${LEADER} s`, "split-down"],
  [`${LEADER} c`, "close"],
  [`${LEADER} w`, "focus-next"],
  [`${LEADER} h`, "focus-left"],
  [`${LEADER} j`, "focus-down"],
  [`${LEADER} k`, "focus-up"],
  [`${LEADER} l`, "focus-right"],
  [`${LEADER} left`, "focus-left"],
  [`${LEADER} down`, "focus-down"],
  [`${LEADER} up`, "focus-up"],
  [`${LEADER} right`, "focus-right"],
];
for (const [spec, command] of bindings) core.keymap.bind(spec, `${CORE}:${command}`);
setSurfaces((owner, signal) => createSurface(core, owner, signal));

term.run({
  event(event: TermEvent): void {
    core.event(event);
  },
  draw(): void {
    core.draw();
  },
});
