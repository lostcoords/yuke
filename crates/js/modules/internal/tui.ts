/** The boot of the terminal interface: the core on the terminal and the keys of the core commands. */
import { clipboardReadImage } from "yuke:internal/native";
import { type TermEvent, term } from "yuke:internal/term";
import { CORE, Core } from "yuke:internal/tui/core";
import { setSurfaces } from "yuke:internal/tui/host";
import { createSurface } from "yuke:internal/tui/surface";

const core = new Core({
  width: () => term.width,
  height: () => term.height,
  background: () => term.background,
  truecolor: () => term.truecolor,
  text: (column, row, text, style, right) => term.text(column, row, text, style, right),
  fill: (column, row, width, height, style) => term.fill(column, row, width, height, style),
  cursor: (cursor) => term.cursor(cursor),
  title: (title) => term.title(title),
  requestFrame: (delay) => term.requestFrame(delay),
  after: (delay, callback) => {
    const timer = setTimeout(callback, delay);
    return () => clearTimeout(timer);
  },
  // A monotonic clock, so a change of the system time does not move a duration.
  now: () => performance.now(),
  copy: (text) => term.copy(text),
  readImage: async () => {
    const bytes = await clipboardReadImage();
    return bytes === undefined ? undefined : Object.freeze({ bytes, mimeType: "image/png" });
  },
  quit: (text) => term.quit(text),
  suspend: () => term.suspend(),
  reload: (snapshot) => term.reload(snapshot),
  startup: () => term.startup,
});

core.keymap.add("ctrl+q", `${CORE}:quit`);
core.keymap.add("ctrl+z", `${CORE}:suspend`);
setSurfaces((owner, signal) => createSurface(core, owner, signal));

term.run({
  event(event: TermEvent): void {
    core.event(event);
  },
  draw(): void {
    core.draw();
  },
});
