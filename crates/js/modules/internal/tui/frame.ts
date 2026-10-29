/**
 * `createFrame` of `yuke:test`: the real core on a `TestScreen` instead of the terminal. Each input goes to
 * `Core.event`, and a frame follows each input.
 */
import { TestScreen } from "yuke:internal/native";
import { Core } from "yuke:internal/tui/core";
import { parseKeys } from "yuke:internal/tui/keys";
import { createMount } from "yuke:internal/tui/mount";
import { createSurface } from "yuke:internal/tui/surface";
import type { Frame, FrameTest, TestSurface } from "yuke:test";
import type { KeyCode, KeyEvent, MouseEvent, Size, ViewFactory } from "yuke:tui";

const NONE = Object.freeze({ shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false });

export function createFrame(size: Size, create?: ViewFactory): FrameTest {
  let width = size.width;
  let height = size.height;
  const screen = new TestScreen(width, height);
  const copies: string[] = [];
  const surfaces = new Set<TestSurface>();
  const core = new Core({
    width: () => width,
    height: () => height,
    background: () => "dark",
    truecolor: () => true,
    text: (column, row, text, style) => {
      screen.text(column, row, text, style);
    },
    fill: (column, row, fillWidth, fillHeight, style) => screen.fill(column, row, fillWidth, fillHeight, style),
    cursor: (cursor) => screen.cursor(cursor),
    // Each input draws a frame after it, and `draw()` draws one on demand.
    requestFrame: () => {},
    copy: (text) => {
      copies.push(text);
    },
    quit: () => {},
    suspend: () => {},
    reload: () => {},
  });
  const root = create === undefined ? undefined : core.scene.setRoot("test", create);
  let frame: Frame;
  const draw = (): Frame => {
    screen.clear();
    core.draw();
    const drawn = screen.frame();
    frame = Object.freeze({ width: drawn.width, height: drawn.height, cells: drawn.cells, cursor: drawn.cursor });
    return frame;
  };
  draw();
  return Object.freeze({
    get frame(): Frame {
      return frame;
    },
    copies,
    surface(name: string): TestSurface {
      const mount = createMount(() => surfaces.delete(surface));
      const surface: TestSurface = Object.freeze({
        close: mount.close,
        signal: mount.signal,
        tui: createSurface(core, name, mount.signal),
      });
      surfaces.add(surface);
      return surface;
    },
    draw,
    key(event: KeyEvent | string): void {
      for (const key of typeof event === "string" ? parseKeys(event).map(eventOf) : [event]) {
        core.event(key);
        draw();
      }
    },
    mouse(event: MouseEvent): void {
      core.event(event);
      draw();
    },
    paste(text: string): void {
      core.event({ type: "paste", text });
      draw();
    },
    resize(next: Size): void {
      width = next.width;
      height = next.height;
      screen.resize(width, height);
      core.event({ type: "resize", w: width, h: height });
      draw();
    },
    start(snapshot?: string): void {
      core.event(snapshot === undefined ? { type: "start" } : { type: "start", snapshot });
      draw();
    },
    snapshot: () => core.snapshot(),
    [Symbol.dispose](): void {
      for (const surface of [...surfaces]) surface.close();
      root?.close();
      // The layout after the root closes ends the mounts of the widgets that left.
      core.scene.layout();
    },
  });
}

/** The key event of one stroke of `parseKeys`, without the kitty fields `shifted` and `baseLayout`. */
function eventOf(stroke: string): KeyEvent {
  const cut = stroke.endsWith("+") ? stroke.length - 2 : stroke.lastIndexOf("+");
  const modifiers = cut < 0 ? [] : stroke.slice(0, cut).split("+");
  const name = stroke.slice(cut + 1);
  const ctrl = modifiers.includes("ctrl");
  const alt = modifiers.includes("alt");
  const superKey = modifiers.includes("super");
  const character = name === "space" ? " " : [...name].length === 1 ? name : "";
  return {
    type: "key",
    code: character === "" ? (name as KeyCode) : "character",
    character,
    shifted: "",
    baseLayout: "",
    text: ctrl || alt || superKey ? "" : character,
    modifiers: { ...NONE, ctrl, alt, super: superKey, shift: modifiers.includes("shift") },
  };
}
