/**
 * The core of the terminal interface: the registries, the scene, the pane tree, and the text widgets on a driver of
 * the terminal. A key goes to the `beforeKeymap` handlers of the focused text widget first. Then it goes to the keymap
 * and along the focus path. An Escape that nothing takes closes the top modal.
 */

import { failureOf } from "yuke:internal/failure";
import type { TermStyle } from "yuke:internal/native";
import type { TermEvent } from "yuke:internal/term";
import type { After } from "yuke:internal/tui/clock";
import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { strokeOf } from "yuke:internal/tui/keys";
import { Notices } from "yuke:internal/tui/notices";
import { type DefaultPaneEntry, PaneTree } from "yuke:internal/tui/panes";
import { type SavedPane, type SavedPanes, ViewTypes } from "yuke:internal/tui/restore";
import { Scene } from "yuke:internal/tui/scene";
import { StatusItems } from "yuke:internal/tui/status";
import { Styles } from "yuke:internal/tui/styles";
import { WidgetMounts } from "yuke:internal/tui/widgets";
import { frozen } from "yuke:internal/values";
import type { CanvasStyle, ClipboardImage, Cursor, Disposer, FocusChange, Startup, Style, View } from "yuke:tui";

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
  /** Call `callback` once after `delay` milliseconds. The returned function cancels the call. */
  readonly after: After;
  /** The time in milliseconds of the clock of `after`. */
  readonly now: () => number;
  readonly copy: (text: string) => void;
  readonly readImage: () => Promise<ClipboardImage | undefined>;
  readonly quit: () => void;
  readonly suspend: () => void;
  readonly reload: (snapshot: string) => void;
  /** How the terminal interface started. The core reads it once. */
  readonly startup: () => Startup;
}

/** The source of the faults and the commands of the core itself. */
export const CORE = "core";

/** The status item of the pending keys of a sequence. */
const KEYS_ITEM = `${CORE}:keys`;

export class Core {
  readonly notices = new Notices();
  readonly status: StatusItems;
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
    this.status = new StatusItems(frame);
    this.keymap = new Keymap(
      this.commands,
      () => {
        frame();
        // The keys of a sequence wait for their next stroke, so the bar shows them.
        const pending = this.keymap.pending();
        if (pending === "") this.status.delete(KEYS_ITEM);
        else this.status.set(KEYS_ITEM, { text: pending, side: "right", order: -1, priority: 100 });
      },
      driver.after,
    );
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
    const entry = { owner, listener };
    this.#focusListeners.add(entry);
    return () => {
      this.#focusListeners.delete(entry);
    };
  }

  /** Call `callback` of the plugin `owner` once after `delay` milliseconds, then draw a frame. A throw is a notice. */
  after(owner: string, delay: number, callback: () => void): Disposer {
    return this.driver.after(delay, () => {
      try {
        callback();
      } catch (error) {
        this.notices.add("error", owner, `a timer failed: ${failureOf(error)}`);
      }
      this.driver.requestFrame();
    });
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

  /** Handle one event of the frame loop. The frame loop draws once after a batch of events. */
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
        this.notices.add(event.level, event.source, event.text, event.sessionId);
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

  /** The saved panes for a reload: the tree, the split ratios, the focus, and the saved view of each pane. */
  snapshot(): string {
    return JSON.stringify(this.panes.snapshot((view, owner) => this.#save(view, owner)));
  }

  /** Rebuild the panes of a snapshot. A snapshot that does not read gives the default layout and one notice. */
  restore(text: string): void {
    let saved: SavedPanes;
    try {
      saved = JSON.parse(text) as SavedPanes;
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
   * The saved view of a pane of `owner`, or `null` without a snapshot or after a fault.
   * A bare type gets the prefix of `owner`.
   */
  #save(view: View, owner: string): SavedPane {
    if (view.snapshot === undefined) return null;
    const saved = this.scene.guard(view, owner, undefined, () => view.snapshot?.());
    if (saved === undefined) return null;
    return { type: saved.type.includes(":") ? saved.type : `${owner}:${saved.type}`, state: saved.state };
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
  }
}
