/**
 * The boot of the terminal interface: the core on the terminal, the keys of the core commands, and a placeholder
 * pane that shows the newest notice. The bundled plugins of step 4 take over the keys and the visible parts.
 */
import { type TermEvent, term } from "yuke:internal/term";
import { CORE, Core } from "yuke:internal/tui/core";
import { strokeOf } from "yuke:internal/tui/keys";
import type { Canvas, View } from "yuke:tui";

const LEADER = "ctrl+k";
const HINT = `ctrl+q quits · ctrl+z suspends · ${LEADER} then v/s split, c closes, h/j/k/l move`;

/**
 * The view of a pane that holds nothing: the size, the reload count of the start snapshot, the newest notice, and the
 * last key, so a key that reaches yuke shows.
 */
function placeholder(core: Core): View {
  return {
    draw(canvas: Canvas, focused: boolean): void {
      canvas.text(0, 0, `yuke ${term.width}x${term.height} ${term.background} reloads ${reloads}`, {
        bold: true,
        ...(focused ? { fg: "accent" as const } : {}),
      });
      const notice = core.notices.list().at(-1);
      if (notice !== undefined) {
        const count = notice.count > 1 ? ` (${notice.count})` : "";
        canvas.text(0, 1, `${notice.level} ${notice.source}: ${notice.text}${count}`);
      }
      canvas.text(0, 2, HINT, { dim: true });
      if (lastKey !== "") canvas.text(0, 3, `last key ${lastKey}`, { dim: true });
    },
  };
}

let reloads = 0;
let lastKey = "";
const core = new Core(
  {
    width: () => term.width,
    height: () => term.height,
    background: () => term.background,
    truecolor: () => term.truecolor,
    text: (column, row, text, style) => {
      term.text(column, row, text, style);
    },
    fill: (column, row, width, height, style) => term.fill(column, row, width, height, style),
    cursor: (point) => (point === undefined ? term.cursor(0, 0, false) : term.cursor(point.column, point.row)),
    requestFrame: (delay) => term.requestFrame(delay),
    quit: () => term.quit(),
    suspend: () => term.suspend(),
    reload: () => term.reload(JSON.stringify({ reloads: reloads + 1 })),
  },
  placeholder,
);

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

term.run({
  event(event: TermEvent): void {
    if (event.type === "start" && event.snapshot !== undefined) {
      reloads = (JSON.parse(event.snapshot) as { reloads?: number }).reloads ?? 0;
    }
    if (event.type === "key") lastKey = strokeOf(event) || event.code;
    core.event(event);
  },
  draw(): void {
    core.draw();
  },
});
