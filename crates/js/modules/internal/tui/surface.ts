/**
 * The surface of one plugin: the frozen `Tui` of `ctx.get("tui")`. Each registration and mount of the surface belongs
 * to the plugin; the abort of its signal removes the rest, and later calls throw. A bare name gets the plugin prefix.
 */
import type { Core } from "yuke:internal/tui/core";
import { dialogView } from "yuke:internal/tui/dialog";
import { TextEditor } from "yuke:internal/tui/editor";
import { bottom } from "yuke:internal/tui/layout";
import { Picker } from "yuke:internal/tui/picker";
import { measure } from "yuke:internal/tui/text";
import { TextView } from "yuke:internal/tui/text-view";
import type {
  ClipboardImage,
  Command,
  CommandItem,
  ConfirmOptions,
  DefaultPane,
  DialogOptions,
  Direction,
  FocusChange,
  FocusDirection,
  InputEvent,
  InputOptions,
  Mount,
  Notice,
  OverlayOptions,
  Pane,
  Panes,
  RestoreView,
  RootFactory,
  SelectOptions,
  Size,
  Startup,
  StatusEntry,
  StatusItem,
  StylePatch,
  Theme,
  Tui,
  View,
  ViewFactory,
  WidgetMount,
} from "yuke:tui";

/** The rows of a dialog at the bottom of the screen without `rows` or `place`. */
const DIALOG_ROWS = 13;

/** The most rows of the text of a confirm. A longer text scrolls. */
const CONFIRM_ROWS = 8;

/** The cleanups of the registrations and mounts of one plugin, newest first at the stop. */
class Scope {
  readonly #owner: string;
  readonly #signal: AbortSignal;
  readonly #report: (text: string) => void;
  readonly #cleanups = new Set<() => void>();

  constructor(owner: string, signal: AbortSignal, report: (text: string) => void) {
    this.#owner = owner;
    this.#signal = signal;
    this.#report = report;
    if (signal.aborted) this.#stop();
    else signal.addEventListener("abort", () => this.#stop(), { once: true });
  }

  /** Throw after the stop of the plugin, also in an abort listener that runs before the one of the scope. */
  check(): void {
    if (this.#signal.aborted) {
      throw new TypeError(`plugin ${this.#owner} stopped: its tui takes no more calls`);
    }
  }

  /** Keep `dispose` until the stop. The returned disposer leaves the scope, so a closed registration holds nothing. */
  own(dispose: () => void): () => void {
    const cleanup = (): void => {
      if (!this.#cleanups.delete(cleanup)) return;
      dispose();
    };
    this.#cleanups.add(cleanup);
    return cleanup;
  }

  /** Close `mount` at the stop. A mount that closes before leaves the scope. */
  ownMount(mount: Mount): void {
    if (mount.signal.aborted) return;
    const cleanup = this.own(() => mount.close());
    mount.signal.addEventListener("abort", cleanup, { once: true });
  }

  #stop(): void {
    for (const cleanup of [...this.#cleanups].toReversed()) {
      try {
        cleanup();
      } catch (error) {
        this.#report(`a cleanup of the tui failed: ${String(error)}`);
      }
    }
  }
}

/** The surface of the plugin `owner`, which stops with `signal`. */
export function createSurface(core: Core, owner: string, signal: AbortSignal): Tui {
  const scope = new Scope(owner, signal, (text) => core.notices.add("error", owner, text));
  // The stop of the plugin deletes its status items.
  scope.own(() => core.status.deleteOwned(owner));
  const prefix = `${owner}:`;
  /** The qualified form of `name`: a bare name gets the prefix of this plugin. */
  const lookup = (name: string): string => {
    return name.includes(":") ? name : `${prefix}${name}`;
  };
  /** The qualified form of a name to register: a qualified name must have the prefix of this plugin. */
  const own = (name: string): string => {
    const qualified = lookup(name);
    if (!qualified.startsWith(prefix)) {
      throw new TypeError(`plugin ${owner} registers only names of its own: ${prefix}…, not ${name}`);
    }
    return qualified;
  };
  // Each call checks the scope first, so a stopped plugin gets a clear error.
  const live =
    <A extends unknown[], R>(f: (...args: A) => R) =>
    (...args: A): R => {
      scope.check();
      return f(...args);
    };
  const mounted = <M extends Mount>(mount: M): M => {
    scope.ownMount(mount);
    return mount;
  };

  const panes: Panes = Object.freeze({
    view: core.panes.view,
    get active(): Pane | undefined {
      scope.check();
      return core.panes.active;
    },
    split: live(
      (create: ViewFactory, options?: { readonly direction?: Direction | undefined }): Pane =>
        mounted(core.panes.split(owner, create, options?.direction ?? "row")),
    ),
    focus: live((direction: FocusDirection): boolean => core.panes.focus(direction)),
    focusNext: live((): void => core.panes.focusNext()),
    setDefault: live((create: DefaultPane): (() => void) => {
      return scope.own(core.setDefaultPane({ owner, create, adopt: (mount) => scope.ownMount(mount), signal }));
    }),
  });

  const setTitle = live((title: () => string): (() => void) => scope.own(core.setTitle({ title, signal })));

  const addQuitGuard = live((guard: (quit: (text?: string) => void) => void): (() => void) =>
    scope.own(core.addQuitGuard(guard)),
  );
  const dialog = live((options: DialogOptions): Mount => {
    const rows = options.rows ?? DIALOG_ROWS;
    // The view forms before the overlay, so a bad key throws to the caller, not as a fault of the overlay.
    const view = dialogView(options);
    const mount = mounted(
      core.scene.overlay(owner, () => view, {
        place: (size) => bottom(size, rows),
      }),
    );
    const signal = options.signal;
    if (signal?.aborted === true) {
      mount.close();
      return mount;
    }
    if (signal !== undefined) {
      const close = (): void => mount.close();
      signal.addEventListener("abort", close, { once: true });
      mount.signal.addEventListener("abort", () => signal.removeEventListener("abort", close), { once: true });
    }
    return mount;
  });
  const select = live(
    <T>(options: SelectOptions<T>): Promise<T | undefined> =>
      new Promise((resolve) => {
        let picked: T | undefined;
        // Two equal items are one choice, so each item has one place, and that place is its id.
        const items = [...new Set(options.items)];
        const picker = new Picker<T>({
          items,
          id: (item) => String(items.indexOf(item)),
          label: options.label,
          detail: options.detail,
          rank: options.rank,
          render: options.render,
          onChoose: (item) => {
            picked = item;
            mount.close();
          },
          onCancel: () => mount.close(),
        });
        const title = options.title;
        const mount = dialog({
          title,
          body: picker,
          signal: options.signal,
        });
        mount.signal.addEventListener("abort", () => resolve(picked), { once: true });
        // An aborted `signal` closes the dialog before this listener attaches.
        if (mount.signal.aborted) resolve(undefined);
      }),
  ) as Tui["select"];

  const input = live(
    (options: InputOptions): Promise<string | undefined> =>
      new Promise((resolve) => {
        let answer: string | undefined;
        let failure: string | undefined;
        let pending = false;
        const accept = async (text: string): Promise<void> => {
          // A throw or a rejection of the check keeps the dialog, with its message below the field.
          try {
            await options.onSubmit?.(text);
          } catch (error) {
            failure = error instanceof Error ? error.message : String(error);
            core.driver.requestFrame();
            return;
          } finally {
            pending = false;
          }
          answer = text;
          mount.close();
        };
        const text = options.text ?? "";
        const editor = new TextEditor({
          role: "field",
          multiline: false,
          mask: options.mask,
          placeholder: options.placeholder,
          state: { text, spans: [], selection: { anchor: text.length, head: text.length } },
          onSubmit: (state) => {
            if (pending) return;
            pending = true;
            failure = undefined;
            void accept(state.text);
          },
        });
        const body: View = {
          focusable: true,
          initialFocus: editor,
          layout: (size) => [
            { view: editor, rect: { column: 1, row: 0, width: Math.max(0, size.width - 2), height: 1 } },
          ],
          draw: (canvas) => {
            if (failure !== undefined) canvas.text(1, 1, failure, "dialog.error");
          },
        };
        const title = options.title;
        const mount = dialog({
          title,
          body,
          rows: (title === undefined ? 0 : 1) + 3,
          signal: options.signal,
        });
        mount.signal.addEventListener("abort", () => resolve(answer), { once: true });
        // An aborted `signal` closes the dialog before this listener attaches.
        if (mount.signal.aborted) resolve(undefined);
      }),
  );

  const confirm = live(
    (options: ConfirmOptions): Promise<boolean> =>
      new Promise((resolve) => {
        let confirmed = false;
        const document = {
          id: "confirm",
          items: [{ id: "text", sections: [{ id: "text", kind: "text" as const, text: options.text }] }],
        };
        // The rows of the text at the width of the screen now, so a short question gets a short dialog.
        const lines = options.text
          .split("\n")
          .reduce((sum, line) => sum + Math.max(1, Math.ceil(measure(line) / Math.max(1, core.driver.width() - 2))), 0);
        const title = options.title;
        const mount = dialog({
          title,
          body: new TextView({ document }),
          keys: [
            {
              key: "enter",
              label: options.confirmLabel ?? "yes",
              run: () => {
                confirmed = true;
                mount.close();
              },
            },
            { key: "esc", label: "no", run: () => mount.close() },
          ],
          rows: (title === undefined ? 0 : 1) + Math.min(lines, CONFIRM_ROWS) + 1,
          signal: options.signal,
        });
        mount.signal.addEventListener("abort", () => resolve(confirmed), { once: true });
        if (mount.signal.aborted) resolve(false);
      }),
  );

  return Object.freeze({
    get size(): Size {
      scope.check();
      return Object.freeze({ width: core.driver.width(), height: core.driver.height() });
    },
    get background(): "dark" | "light" {
      scope.check();
      return core.driver.background();
    },
    get truecolor(): boolean {
      scope.check();
      return core.driver.truecolor();
    },
    get startup(): Startup {
      scope.check();
      return core.startup;
    },
    panes,
    get focused(): View | undefined {
      scope.check();
      return core.scene.focused;
    },
    focus: live((view: View): boolean => core.scene.focus(view)),
    addFocusListener: live((listener: (change: FocusChange) => void): (() => void) =>
      scope.own(core.addFocusListener(listener)),
    ),
    addInputHandler: live((handler: (event: InputEvent) => boolean): (() => void) =>
      scope.own(core.addInputHandler(handler)),
    ),
    now: live((): number => core.driver.now()),
    addTimer: live((delay: number, callback: () => void): (() => void) => {
      // A fired timer leaves the scope, so a callback that calls `addTimer` again leaves no old disposer.
      const cancel: () => void = scope.own(
        core.addTimer(owner, delay, () => {
          cancel();
          callback();
        }),
      );
      return cancel;
    }),
    wrapRoot: live((create: RootFactory): Mount => mounted(core.scene.wrapRoot(owner, create))),
    overlay: live(
      (create: ViewFactory, options?: OverlayOptions): Mount => mounted(core.scene.overlay(owner, create, options)),
    ),
    dialog,
    setTitle,
    addQuitGuard,
    select,
    input,
    confirm,
    commands: Object.freeze({
      add: live((command: Command): (() => void) => {
        return scope.own(core.commands.add(command, own(command.name)));
      }),
      run: live((name: string, args?: unknown): boolean => core.commands.run(lookup(name), args)),
      list: live((): readonly CommandItem[] => core.commands.list()),
    }),
    keys: Object.freeze({
      add: live((spec: string, command: string, options?: { readonly in?: string | undefined }): (() => void) =>
        scope.own(core.keymap.add(spec, lookup(command), options?.in === undefined ? {} : { in: options.in })),
      ),
      pending: live((): string => core.keymap.pending()),
      keysOf: live((name: string): readonly string[] => core.keymap.keysOf(lookup(name))),
    }),
    styles: Object.freeze({
      add: live((groups: Readonly<Record<string, StylePatch>>): (() => void) => scope.own(core.styles.add(groups))),
      addTheme: live((name: string, theme: Theme): (() => void) => scope.own(core.styles.addTheme(name, theme))),
      themes: live((): readonly string[] => core.styles.themes()),
      get theme(): string {
        scope.check();
        return core.styles.theme;
      },
      setTheme: live((name: string): void => core.styles.setTheme(name)),
    }),
    status: Object.freeze({
      set: live((id: string, entry: StatusEntry): (() => void) => core.status.set(own(id), entry)),
      delete: live((id: string): void => core.status.delete(own(id))),
      list: live((): readonly StatusItem[] => core.status.list()),
      addChangeListener: live((listener: () => void): (() => void) =>
        scope.own(core.status.addChangeListener(listener)),
      ),
    }),
    notices: Object.freeze({
      list: live((): readonly Notice[] => core.notices.list()),
      addListener: live((listener: (notice: Notice) => void): (() => void) =>
        scope.own(core.notices.addListener(listener)),
      ),
    }),
    widgets: Object.freeze({
      list: live((): readonly WidgetMount[] => core.widgets.list()),
      addWatcher: live((attach: (mount: WidgetMount) => (() => void) | undefined): (() => void) =>
        scope.own(core.widgets.addWatcher(owner, attach)),
      ),
    }),
    views: Object.freeze({
      add: live((type: string, restore: RestoreView): (() => void) => {
        return scope.own(core.views.add(own(type), { owner, restore, adopt: (mount) => scope.ownMount(mount) }));
      }),
    }),
    requestFrame: live((delay?: number): void => core.driver.requestFrame(delay)),
    clipboard: Object.freeze({
      writeText: live((text: string): void => core.driver.copy(text)),
      readImage: live((): Promise<ClipboardImage | undefined> => core.driver.readImage()),
    }),
  });
}
