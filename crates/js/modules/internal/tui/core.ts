/**
 * The core of the terminal interface: the registries, the scene, the pane tree, and the text widgets on a driver of
 * the terminal. A key goes to the `beforeKeymap` handlers of the focused text widget first. Then it goes to the keymap
 * and along the focus path. An Escape that nothing takes closes the top modal.
 */

import { failureOf } from "yuke:internal/failure";
import type { TermStyle } from "yuke:internal/native";
import type { TermEvent } from "yuke:internal/term";
import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { strokeOf } from "yuke:internal/tui/keys";
import { Notices } from "yuke:internal/tui/notices";
import { type DefaultPaneEntry, PaneTree } from "yuke:internal/tui/panes";
import { Picker } from "yuke:internal/tui/picker";
import { readSnapshot, type SavedPane, ViewTypes } from "yuke:internal/tui/restore";
import { Scene } from "yuke:internal/tui/scene";
import { Styles } from "yuke:internal/tui/styles";
import { WidgetMounts } from "yuke:internal/tui/widgets";
import { frozen } from "yuke:internal/values";
import type { CanvasStyle, CommandItem, Cursor, Disposer, FocusChange, Mount, Startup, Style, View } from "yuke:tui";

/** A default pane and the signal of its plugin. The core asks no plugin that stops for a pane. */
export interface DefaultPaneSlot extends DefaultPaneEntry {
  readonly signal: AbortSignal;
}

/** What the core needs from the terminal. The boot passes `term`; a test passes a fake. */
export interface Driver {
  readonly width: () => number;
  readonly height: () => number;
  readonly background: () => "dark" | "light";
  readonly truecolor: () => boolean;
  readonly text: (column: number, row: number, text: string, style: TermStyle) => void;
  readonly fill: (column: number, row: number, width: number, height: number, style: TermStyle) => void;
  readonly cursor: (cursor: Cursor | undefined) => void;
  readonly requestFrame: (delay?: number) => void;
  readonly copy: (text: string) => void;
  readonly quit: () => void;
  readonly suspend: () => void;
  readonly reload: (snapshot: string) => void;
  /** How the terminal interface started. The core reads it once. */
  readonly startup: () => Startup;
}

/** The source of the faults and the commands of the core itself. */
export const CORE = "core";

/** The row limit of the palette. The search field counts as a row. */
const PALETTE_ROWS = 12;

export class Core {
  readonly notices = new Notices();
  readonly views = new ViewTypes();
  readonly styles: Styles;
  readonly commands: Commands;
  readonly keymap: Keymap;
  readonly panes: PaneTree;
  readonly scene: Scene;
  readonly widgets: WidgetMounts;
  readonly driver: Driver;
  readonly startup: Startup;
  #defaultPane: DefaultPaneSlot | undefined;
  /** The start event came without a snapshot and found no default pane. The next default pane makes the start pane. */
  #startWaits = false;
  readonly #focusListeners = new Set<{ readonly owner: string; readonly listener: (change: FocusChange) => void }>();

  constructor(driver: Driver) {
    this.driver = driver;
    this.startup = frozen(driver.startup());
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
    this.widgets = new WidgetMounts(
      {
        requestFrame: frame,
        // A key sequence belongs to the contexts where it started.
        contextsChanged: () => this.keymap.cancel(),
        report: (text) => report(CORE, text),
        copy: (text) => driver.copy(text),
      },
      report,
    );
    this.panes = new PaneTree({
      defaultPane: () => {
        const slot = this.#defaultPane;
        return slot === undefined || slot.signal.aborted ? undefined : slot;
      },
      focus: (view) => this.scene.focusRoot(view),
      report,
      requestFrame: frame,
    });
    this.scene = new Scene(
      {
        screen: {
          text: driver.text,
          fill: driver.fill,
          resolve: (style: CanvasStyle | undefined) => {
            if (style === undefined) return {};
            if (!Array.isArray(style)) return this.styles.resolve(style as string | Style);
            return Object.freeze(Object.assign({}, ...style.map((item) => this.styles.resolve(item))));
          },
        },
        size: () => ({ width: driver.width(), height: driver.height() }),
        cursor: driver.cursor,
        requestFrame: frame,
        report,
        paneOf: (view) => this.panes.leafOf(view),
        fallbackFocus: () => this.panes.activeView(),
        focusMoved: (rootPath, change) => {
          this.panes.noteFocus(rootPath);
          // A key sequence belongs to the focus where it started.
          this.keymap.cancel();
          if (change !== undefined) this.#focusChanged(change);
        },
        placed: (widgets) => this.widgets.update(widgets),
      },
      this.panes.view,
    );
    this.#addCommands();
  }

  /** Give each later change of `tui.focused` to `listener` of the plugin `owner`. A throw reports and removes it. */
  onFocus(owner: string, listener: (change: FocusChange) => void): Disposer {
    if (typeof listener !== "function") throw new TypeError("a focus listener is a function");
    const entry = { owner, listener };
    this.#focusListeners.add(entry);
    return () => {
      this.#focusListeners.delete(entry);
    };
  }

  /**
   * Make `slot` the default pane. A start that waits gets its first pane now. A second live default pane throws a
   * `TypeError`.
   */
  setDefaultPane(slot: DefaultPaneSlot): Disposer {
    const current = this.#defaultPane;
    if (current !== undefined && !current.signal.aborted) {
      throw new TypeError(`plugin ${current.owner} sets the default pane`);
    }
    this.#defaultPane = slot;
    if (this.#startWaits) this.#startWaits = !this.panes.start();
    return () => {
      if (this.#defaultPane === slot) this.#defaultPane = undefined;
    };
  }

  /** Handle one event of the frame loop. Each one draws a frame after it. */
  event(event: TermEvent): void {
    switch (event.type) {
      case "key": {
        this.scene.layout();
        if (this.scene.beforeKeymap(event)) {
          this.keymap.cancel();
          return;
        }
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
        // The plugins of a first start load after this event, and those of a reload before it.
        if (event.snapshot !== undefined) this.restore(event.snapshot);
        else this.#startWaits = !this.panes.start();
        return;
      case "resize":
      case "background":
        return;
    }
  }

  /**
   * Open the command palette for `owner`: a modal picker of the enabled commands at the bottom. A choice closes the
   * palette, gives the focus back, and then runs the command. Esc closes the palette and calls `cancel`.
   */
  palette(owner: string, cancel?: () => void): Mount {
    const prefix = `${CORE}:`;
    const mount = this.scene.overlay(
      owner,
      () =>
        new Picker<CommandItem>({
          items: this.commands.list().filter((item) => item.enabled),
          key: (item) => item.name,
          // The core commands are the base set, so they show without their prefix.
          label: (item) => `/${item.name.startsWith(prefix) ? item.name.slice(prefix.length) : item.name}`,
          detail: (item) =>
            [item.description ?? "", this.keymap.keysOf(item.name).join(", ")].filter(Boolean).join(" · "),
          choose: (item) => {
            mount.close();
            // The command runs with the focus that the palette took, not in the palette.
            this.scene.layout();
            this.commands.run(item.name);
          },
          cancel: () => {
            mount.close();
            cancel?.();
          },
        }),
      {
        place: (size) => {
          const height = Math.min(PALETTE_ROWS, size.height);
          return { column: 0, row: size.height - height, width: size.width, height };
        },
      },
    );
    return mount;
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

  #focusChanged(change: FocusChange): void {
    for (const entry of [...this.#focusListeners]) {
      try {
        entry.listener(change);
      } catch (error) {
        this.#focusListeners.delete(entry);
        this.notices.add("error", entry.owner, `a focus listener failed: ${failureOf(error)}`);
      }
    }
  }

  #addCommands(): void {
    const driver = this.driver;
    const add = (name: string, description: string, run: () => void): void => {
      this.commands.add({ name: `${CORE}:${name}`, description, run });
    };
    add("quit", "Quit yuke", () => driver.quit());
    add("suspend", "Suspend yuke to the shell", () => driver.suspend());
    add("reload", "Reload the plugins", () => driver.reload(this.snapshot()));
    add("split-right", "Split the pane to the right", () => this.panes.splitDefault("row"));
    add("split-down", "Split the pane down", () => this.panes.splitDefault("column"));
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
    add("palette", "Open the command palette", () => {
      this.palette(CORE);
    });
  }
}
