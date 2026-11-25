/**
 * The core of the terminal interface: the registries, the scene, the main view, and the text widgets on a driver of
 * the terminal. A key goes to the `beforeKeymap` handlers of the focused text widget first. Then it goes to the keymap
 * and along the focus path. An Escape that nothing takes closes the top modal.
 */

import { announce } from "yuke:internal/facts";
import { failureOf } from "yuke:internal/failure";
import { Listeners } from "yuke:internal/listeners";
import type { TermStyle } from "yuke:internal/native";
import { Stack } from "yuke:internal/stack";
import type { TermEvent } from "yuke:internal/term";
import type { After } from "yuke:internal/tui/clock";
import { Commands } from "yuke:internal/tui/commands";
import { Keymap } from "yuke:internal/tui/keymap";
import { strokeOf } from "yuke:internal/tui/keys";
import { createMount, startView } from "yuke:internal/tui/mount";
import { Notices } from "yuke:internal/tui/notices";
import { Scene } from "yuke:internal/tui/scene";
import { StatusItems } from "yuke:internal/tui/status";
import { Styles } from "yuke:internal/tui/styles";
import { PlacedWidgets } from "yuke:internal/tui/widgets";
import { frozen } from "yuke:internal/values";
import type {
  CanvasStyle,
  ClipboardImage,
  Cursor,
  FocusChange,
  InputEvent,
  JsonValue,
  MainFactory,
  Mount,
  Startup,
  View,
} from "yuke:tui";

/** A factory of the main view and its plugin. */
interface MainSlot {
  readonly owner: string;
  readonly create: MainFactory;
}

/** The main view now: its slot, its mount, and its view. A closed mount leaves `view` empty. */
interface Main {
  readonly slot: MainSlot;
  readonly mount: Mount;
  view: View | undefined;
}

/** What a reload keeps of the main view: its plugin, and the value of its `snapshot`. */
interface SavedMain {
  readonly owner: string;
  readonly state: JsonValue;
}

/** A guard of a quit: it calls `quit` to let the quit go on, later or never. */
type QuitGuard = (quit: (text?: string) => void) => void;

/** What the core needs from the terminal. The boot passes `term`; a test passes a fake. */
export interface Driver {
  readonly width: () => number;
  readonly height: () => number;
  readonly background: () => "dark" | "light";
  readonly truecolor: () => boolean;
  /** Write the part of `text` that ends at or before the column `right`, and return the column after the whole text. */
  readonly text: (column: number, row: number, text: string, style: TermStyle, right: number) => number;
  readonly fill: (column: number, row: number, width: number, height: number, style: TermStyle) => void;
  readonly cursor: (cursor: Cursor | undefined) => void;
  /** Show `title` as the window title, or the title of the shell with `undefined`. The core calls it at each draw. */
  readonly title: (title: string | undefined) => void;
  readonly requestFrame: (delay?: number) => void;
  /** Call `callback` once after `delay` milliseconds. The returned function cancels the call. */
  readonly after: After;
  /** The time in milliseconds of the clock of `after`. */
  readonly now: () => number;
  readonly copy: (text: string) => void;
  readonly readImage: () => Promise<ClipboardImage | undefined>;
  /** Quit. The host writes `text`, when there is one, after it restores the terminal. */
  readonly quit: (text?: string) => void;
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
  readonly styles: Styles;
  readonly commands: Commands;
  readonly keymap: Keymap;
  readonly scene: Scene;
  readonly widgets: PlacedWidgets;
  readonly driver: Driver;
  readonly startup: Startup;
  readonly #mains = new Stack<MainSlot>();
  #main: Main | undefined;
  /** The start event came, so a new slot shows at once. */
  #started = false;
  /** The main view of the snapshot of a reload. The first main view after the start takes it, or drops it. */
  #saved: SavedMain | undefined;
  readonly #titles = new Stack<() => string>();
  /** The guards that decide on a quit, in add order. */
  readonly #quitGuards = new Set<{ readonly guard: QuitGuard }>();
  readonly #focusListeners = new Listeners<[FocusChange]>();
  readonly #inputHandlers = new Set<{ readonly handler: (event: InputEvent) => boolean }>();

  constructor(driver: Driver) {
    this.driver = driver;
    this.startup = frozen(driver.startup());
    const frame = (): void => driver.requestFrame();
    const report = (source: string, text: string): void => this.notices.add("error", source, text);
    const themeChanged = (): void =>
      announce("theme.changed", { name: this.styles.theme, background: driver.background() });
    this.styles = new Styles(driver.truecolor, driver.background, frame, themeChanged);
    // A notice changes what a listener, such as the toasts, draws.
    this.notices.addListener(frame);
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
    this.widgets = new PlacedWidgets(
      {
        requestFrame: frame,
        // A key sequence belongs to the contexts where it started.
        contextsChanged: () => this.keymap.cancel(),
        copy: (text) => driver.copy(text),
      },
      report,
    );
    this.scene = new Scene(
      {
        screen: {
          text: driver.text,
          fill: driver.fill,
          resolve: (style: CanvasStyle | undefined) => this.styles.cell(style),
        },
        size: () => ({ width: driver.width(), height: driver.height() }),
        cursor: driver.cursor,
        requestFrame: frame,
        report,
        main: () => this.#main?.view,
        focusMoved: (change) => {
          // A key sequence belongs to the focus where it started.
          this.keymap.cancel();
          if (change !== undefined) this.#focusListeners.call(change);
        },
        placed: (widgets) => this.widgets.update(widgets),
      },
      {
        layout: (size) => {
          const view = this.#main?.view;
          return view === undefined ? [] : [{ view, rect: { column: 0, row: 0, ...size } }];
        },
        draw() {},
      },
    );
    this.#addCommands();
  }

  /** Give each later change of `tui.focusedView` to `listener`. */
  addFocusListener(listener: (change: FocusChange) => void): () => void {
    return this.#focusListeners.add(listener);
  }

  /** Give each input event to `handler` before the scene and the keymap. A `true` answer takes the event. */
  addInputHandler(handler: (event: InputEvent) => boolean): () => void {
    const entry = { handler };
    this.#inputHandlers.add(entry);
    return () => {
      this.#inputHandlers.delete(entry);
    };
  }

  /** Call `callback` of the plugin `owner` once after `delay` milliseconds, then draw a frame. A throw is a notice. */
  addTimer(owner: string, delay: number, callback: () => void): () => void {
    return this.driver.after(delay, () => {
      try {
        callback();
      } catch (error) {
        this.notices.add("error", owner, `A timer failed: ${failureOf(error)}`);
      }
      this.driver.requestFrame();
    });
  }

  /**
   * Make `slot` the factory of the main view until its remover runs. The last call wins, and the remover brings back
   * the slot before it. After the start, each change shows a new main view at once, and the view before closes.
   */
  setMain(slot: MainSlot): () => void {
    const remove = this.#mains.add(slot);
    this.#showMain();
    return () => {
      remove();
      this.#showMain();
    };
  }

  /**
   * Make `title` the window title until its remover runs. The last call wins, and the remover brings back the title
   * before it. Without a title, the terminal shows the title of the shell.
   */
  setTitle(title: () => string): () => void {
    const remove = this.#titles.add(title);
    this.driver.requestFrame();
    return () => {
      remove();
      this.driver.requestFrame();
    };
  }

  /** Add `guard` to the guards of a quit. */
  addQuitGuard(guard: QuitGuard): () => void {
    const entry = { guard };
    this.#quitGuards.add(entry);
    return () => {
      this.#quitGuards.delete(entry);
    };
  }

  /** Handle one event of the frame loop. The frame loop draws once after a batch of events. */
  event(event: TermEvent): void {
    switch (event.type) {
      case "key": {
        this.scene.layout();
        if (this.#takenByHandler(event) || this.scene.beforeKeymap(event)) {
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
        if (!this.#takenByHandler(event)) this.scene.mouse(event);
        return;
      case "paste":
        this.scene.layout();
        if (!this.#takenByHandler(event)) this.scene.paste(event);
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
        this.#started = true;
        // A snapshot of an older yuke has no `main`, so its main view starts new.
        this.#saved =
          event.snapshot === undefined ? undefined : (JSON.parse(event.snapshot) as { main?: SavedMain }).main;
        this.#showMain();
        return;
      case "background":
        announce("theme.changed", { name: this.styles.theme, background: event.background });
        return;
      case "resize":
        return;
    }
  }

  /** What a reload keeps: the plugin of the main view and the value of its `snapshot`. */
  snapshot(): string {
    const main = this.#main;
    const state = main?.view?.snapshot?.();
    return JSON.stringify(main === undefined || state === undefined ? {} : { main: { owner: main.slot.owner, state } });
  }

  /** Lay out and draw each view, and give the terminal the window title. */
  draw(): void {
    this.scene.layout();
    this.scene.draw();
    this.driver.title(this.#titles.top()?.());
  }

  /**
   * Show the main view of the top slot, after the start. The main view before closes. The saved main view of a reload
   * goes to the first main view, when the same plugin makes it.
   */
  #showMain(): void {
    if (!this.#started) return;
    const slot = this.#mains.top();
    if (slot === this.#main?.slot) return;
    this.#main?.mount.close();
    this.#main = undefined;
    this.driver.requestFrame();
    if (slot === undefined) return;
    const saved = this.#saved?.owner === slot.owner ? this.#saved.state : null;
    this.#saved = undefined;
    const main: Main = {
      slot,
      mount: createMount(() => {
        main.view = undefined;
        this.driver.requestFrame();
      }),
      view: undefined,
    };
    this.#main = main;
    main.view = startView(
      slot.owner,
      (own) => slot.create(own, saved),
      main.mount,
      (source, text) => this.notices.add("error", source, text),
    );
    if (main.view !== undefined) this.scene.focusRoot(main.view);
  }

  /** Give `event` to the input handlers, newest first, until one takes it. */
  #takenByHandler(event: InputEvent): boolean {
    for (const entry of [...this.#inputHandlers].toReversed()) {
      // A handler that an earlier handler removed sees no more events.
      if (this.#inputHandlers.has(entry) && entry.handler(event)) return true;
    }
    return false;
  }

  #addCommands(): void {
    const driver = this.driver;
    const add = (name: string, description: string, run: () => void, slash?: string): void => {
      this.commands.add({ name: `${CORE}:${name}`, description, slash, run });
    };
    add(
      "quit",
      "Quit yuke",
      () => {
        // Each guard in add order gets a call, and the quit goes on after the last guard calls its `quit`.
        const guards = [...this.#quitGuards];
        const texts: string[] = [];
        const next = (index: number): void => {
          const entry = guards[index];
          if (entry === undefined) {
            driver.quit(texts.length === 0 ? undefined : texts.join("\n"));
            return;
          }
          // A guard that a stopped plugin removed while an earlier guard waited does not ask.
          if (!this.#quitGuards.has(entry)) {
            next(index + 1);
            return;
          }
          entry.guard((text) => {
            if (text !== undefined) texts.push(text);
            next(index + 1);
          });
        };
        next(0);
      },
      "quit",
    );
    add("suspend", "Suspend yuke to the shell", () => driver.suspend());
    add("reload", "Reload the plugins", () => driver.reload(this.snapshot()), "reload");
  }
}
