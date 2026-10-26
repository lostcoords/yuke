/**
 * The core of the terminal interface: the registries of 3b, the scene, and the pane tree, wired to a driver of the
 * terminal. The keymap sees each key first; a key that it does not take goes along the focus path, and an Escape that
 * nothing takes closes the top modal.
 */

import { failureOf } from "yuke:internal/failure";
import type { TermStyle } from "yuke:internal/native";
import type { TermEvent } from "yuke:internal/term";
import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { strokeOf } from "yuke:internal/tui/keys";
import { Notices } from "yuke:internal/tui/notices";
import { PaneTree } from "yuke:internal/tui/panes";
import { readSnapshot, type SavedPane, ViewTypes } from "yuke:internal/tui/restore";
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
  readonly copy: (text: string) => void;
  readonly quit: () => void;
  readonly suspend: () => void;
  readonly reload: (snapshot: string) => void;
}

/** The source of the faults and the commands of the core itself. */
export const CORE = "core";

export class Core {
  readonly notices = new Notices();
  readonly views = new ViewTypes();
  readonly styles: Styles;
  readonly commands: Commands;
  readonly keymap: Keymap;
  readonly panes: PaneTree;
  readonly scene: Scene;
  readonly driver: Driver;
  readonly #placeholder: () => View;

  /** `placeholder` makes the view of a pane that holds nothing, such as the last pane after its close. */
  constructor(driver: Driver, placeholder: (core: Core) => View) {
    this.driver = driver;
    this.#placeholder = () => placeholder(this);
    const frame = (): void => driver.requestFrame();
    const report = (source: string, text: string): void => this.notices.add("error", source, text);
    this.styles = new Styles(driver.truecolor, driver.background, frame);
    // A notice changes what a listener, such as the toasts, draws.
    this.notices.on(frame);
    // A command name starts with the plugin that owns it, so its fault names that plugin.
    this.commands = new Commands(
      (name, text) => report(name.includes(":") ? name.slice(0, name.indexOf(":")) : CORE, text),
      frame,
    );
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
        if (event.snapshot !== undefined) this.restore(event.snapshot);
        return;
      case "resize":
      case "background":
        return;
    }
  }

  /** The saved panes for a reload: the tree, the split ratios, the focus, and the saved view of each pane. */
  snapshot(): string {
    return JSON.stringify(this.panes.snapshot((view, owner) => this.#save(view, owner)));
  }

  /** Rebuild the panes of a snapshot. A snapshot that does not read gives the default layout and one notice. */
  restore(text: string): void {
    let saved: ReturnType<typeof readSnapshot>;
    try {
      saved = readSnapshot(text);
    } catch (error) {
      this.notices.add("error", CORE, `the saved panes did not read: ${failureOf(error)}`);
      saved = { tree: null, focus: 0 };
    }
    this.panes.restore(saved, (type) => this.views.get(type));
  }

  /** Lay out and draw each view. */
  draw(): void {
    this.scene.layout();
    this.scene.draw();
  }

  /**
   * The saved view of a pane of `owner`, or `null` without a valid snapshot; a state that is no JSON value gives a
   * notice too. A bare type gets the prefix of `owner`.
   */
  #save(view: View, owner: string): SavedPane {
    if (view.snapshot === undefined) return null;
    const saved = this.scene.guard(view, owner, undefined, () => view.snapshot?.());
    if (typeof saved !== "object" || saved === null || typeof saved.type !== "string") return null;
    try {
      // A copy through JSON keeps only what the new runtime can read, and a cycle throws here.
      const text = JSON.stringify(saved.state);
      if (text === undefined) throw new TypeError(`the state is ${typeof saved.state}`);
      return { type: saved.type.includes(":") ? saved.type : `${owner}:${saved.type}`, state: JSON.parse(text) };
    } catch (error) {
      this.notices.add("error", owner, `the snapshot of a pane is no JSON value: ${failureOf(error)}`);
      return null;
    }
  }

  #addCommands(): void {
    const driver = this.driver;
    const add = (name: string, title: string, run: () => void): void => {
      this.commands.add({ name: `${CORE}:${name}`, title, run });
    };
    add("quit", "Quit yuke", () => driver.quit());
    add("suspend", "Suspend yuke to the shell", () => driver.suspend());
    add("reload", "Reload the plugins", () => driver.reload(this.snapshot()));
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
