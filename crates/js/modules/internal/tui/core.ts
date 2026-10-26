/**
 * The core of the terminal interface: the registries of 3b, the scene, and the pane tree, wired to a driver of the
 * terminal. The keymap sees each key first; a key that it does not take goes along the focus path, and an Escape that
 * nothing takes closes the top modal.
 */
import type { TermStyle } from "yuke:internal/native";
import type { TermEvent } from "yuke:internal/term";
import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { strokeOf } from "yuke:internal/tui/keys";
import { Notices } from "yuke:internal/tui/notices";
import { PaneTree } from "yuke:internal/tui/panes";
import { Scene } from "yuke:internal/tui/scene";
import { Styles } from "yuke:internal/tui/styles";
import type { Point, Style, View } from "yuke:tui";

/** What the core needs from the terminal. The boot passes `term`; a test passes a fake. */
export interface Driver {
  readonly width: () => number;
  readonly height: () => number;
  readonly background: () => "dark" | "light";
  readonly truecolor: () => boolean;
  readonly text: (column: number, row: number, text: string, style: TermStyle) => void;
  readonly fill: (column: number, row: number, width: number, height: number, style: TermStyle) => void;
  readonly cursor: (point: Point | undefined) => void;
  readonly requestFrame: (delay?: number) => void;
  readonly quit: () => void;
  readonly suspend: () => void;
  readonly reload: (snapshot: string) => void;
}

/** The source of the faults and the commands of the core itself. */
export const CORE = "core";

export class Core {
  readonly notices = new Notices();
  readonly styles: Styles;
  readonly commands: Commands;
  readonly keymap: Keymap;
  readonly panes: PaneTree;
  readonly scene: Scene;
  readonly #driver: Driver;
  readonly #placeholder: () => View;

  /** `placeholder` makes the view of a pane that holds nothing, such as the last pane after its close. */
  constructor(driver: Driver, placeholder: (core: Core) => View) {
    this.#driver = driver;
    this.#placeholder = () => placeholder(this);
    const frame = (): void => driver.requestFrame();
    const report = (source: string, text: string): void => this.notices.add("error", source, text);
    this.styles = new Styles(driver.truecolor, driver.background, frame);
    // A notice changes what a listener, such as the toasts, draws.
    this.notices.on(frame);
    this.commands = new Commands((text) => report(CORE, text), frame);
    this.keymap = new Keymap(this.commands, frame);
    this.panes = new PaneTree({
      placeholder: this.#placeholder,
      focus: (view) => this.scene.focusRoot(view),
      report,
      requestFrame: frame,
    });
    this.scene = new Scene(
      {
        screen: {
          text: driver.text,
          fill: driver.fill,
          resolve: (style: string | Style | undefined) => (style === undefined ? {} : this.styles.resolve(style)),
        },
        size: () => ({ width: driver.width(), height: driver.height() }),
        cursor: driver.cursor,
        requestFrame: frame,
        report,
        focusableByRole: (view) => this.panes.has(view),
        fallbackFocus: () => this.panes.activeView(),
        focusMoved: (rootPath) => {
          this.panes.noteFocus(rootPath);
          // A key sequence belongs to the focus where it started.
          this.keymap.cancel();
        },
      },
      this.panes.view,
    );
    this.#addCommands();
  }

  /** Handle one event of the frame loop. Each one draws a frame after it. */
  event(event: TermEvent): void {
    switch (event.type) {
      case "key": {
        this.scene.layout();
        if (this.keymap.key(event, this.scene.atoms())) return;
        if (this.scene.key(event)) return;
        if (strokeOf(event) === "esc") this.scene.closeTopModal();
        return;
      }
      case "mouse":
        this.scene.layout();
        this.scene.mouse(event);
        return;
      case "paste":
        this.scene.layout();
        this.scene.paste(event.text);
        return;
      case "focus":
        if (!event.focused) {
          this.scene.cancelCapture();
          this.keymap.cancel();
        }
        return;
      case "notice":
        this.notices.add(event.level, event.source, event.text);
        return;
      case "start":
      case "resize":
      case "background":
        return;
    }
  }

  /** Lay out and draw each view. */
  draw(): void {
    this.scene.layout();
    this.scene.draw();
  }

  #addCommands(): void {
    const driver = this.#driver;
    const add = (name: string, title: string, run: () => void): void => {
      this.commands.add({ name: `${CORE}:${name}`, title, run });
    };
    add("quit", "Quit yuke", () => driver.quit());
    add("suspend", "Suspend yuke to the shell", () => driver.suspend());
    // The snapshot of the panes comes with the restore of 3d.
    add("reload", "Reload the plugins", () => driver.reload("{}"));
    add("split-right", "Split the pane to the right", () => this.panes.split(CORE, () => this.#placeholder(), "row"));
    add("split-down", "Split the pane down", () => this.panes.split(CORE, () => this.#placeholder(), "column"));
    add("close", "Close the pane", () => this.panes.closeActive());
    for (const direction of ["left", "right", "up", "down"] as const) {
      add(
        `focus-${direction}`,
        `Focus the pane ${direction === "up" || direction === "down" ? direction : `on the ${direction}`}`,
        () => {
          this.panes.focus(direction);
        },
      );
    }
    add("focus-next", "Focus the next pane", () => this.panes.focusNext());
  }
}
