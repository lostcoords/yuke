/**
 * The surface of one plugin: the frozen `Tui` of `ctx.get("tui")`. Each registration and mount of the surface belongs
 * to the plugin; the abort of its signal removes the rest, and later calls throw. A bare name gets the plugin prefix.
 */
import type { Core } from "yuke:internal/tui/core";
import type {
  Command,
  CommandItem,
  Direction,
  Disposer,
  FocusChange,
  FocusDirection,
  Mount,
  Notice,
  OverlayOptions,
  Pane,
  Panes,
  RestoreView,
  StylePatch,
  Tui,
  View,
  ViewFactory,
} from "yuke:tui";

/** The cleanups of the registrations and mounts of one plugin, newest first at the stop. */
class Scope {
  readonly #owner: string;
  readonly #signal: AbortSignal;
  readonly #report: (text: string) => void;
  readonly #cleanups = new Set<() => void>();
  #stopped = false;

  constructor(owner: string, signal: AbortSignal, report: (text: string) => void) {
    this.#owner = owner;
    this.#signal = signal;
    this.#report = report;
    if (signal.aborted) this.#stop();
    else signal.addEventListener("abort", () => this.#stop(), { once: true });
  }

  /** Throw after the stop of the plugin, also in an abort listener that runs before the one of the scope. */
  check(): void {
    if (this.#stopped || this.#signal.aborted) {
      throw new TypeError(`plugin ${this.#owner} stopped: its tui takes no more calls`);
    }
  }

  /** Keep `dispose` until the stop. The returned disposer leaves the scope, so a closed registration holds nothing. */
  own(dispose: Disposer): Disposer {
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
    if (this.#stopped) return;
    this.#stopped = true;
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
  const prefix = `${owner}:`;
  /** The qualified form of `name`: a bare name gets the prefix of this plugin. */
  const lookup = (name: string): string => {
    if (typeof name !== "string") throw new TypeError("a name is a string");
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
  });

  return Object.freeze({
    get width(): number {
      scope.check();
      return core.driver.width();
    },
    get height(): number {
      scope.check();
      return core.driver.height();
    },
    get background(): "dark" | "light" {
      scope.check();
      return core.driver.background();
    },
    get truecolor(): boolean {
      scope.check();
      return core.driver.truecolor();
    },
    panes,
    get focused(): View | undefined {
      scope.check();
      return core.scene.focused;
    },
    focus: live((view: View): boolean => core.scene.focus(view)),
    onFocus: live((listener: (change: FocusChange) => void): Disposer => scope.own(core.onFocus(owner, listener))),
    setRoot: live((create: ViewFactory): Mount => mounted(core.scene.setRoot(owner, create))),
    overlay: live(
      (create: ViewFactory, options?: OverlayOptions): Mount => mounted(core.scene.overlay(owner, create, options)),
    ),
    commands: Object.freeze({
      add: live((command: Command): Disposer => {
        if (typeof command !== "object" || command === null) throw new TypeError("a command is an object");
        const { name, title, enabled } = command;
        // The wrapper calls through the object, so a command of a class keeps its `this`.
        return scope.own(
          core.commands.add({
            name: own(name),
            ...(title === undefined ? {} : { title }),
            run: (args) => command.run(args),
            ...(enabled === undefined ? {} : { enabled: () => command.enabled?.() === true }),
          }),
        );
      }),
      run: live((name: string, args?: unknown): boolean => core.commands.run(lookup(name), args)),
      list: live((): readonly CommandItem[] => core.commands.list()),
    }),
    keys: Object.freeze({
      bind: live(
        (spec: string, command: string, options?: { readonly in?: string | undefined }): Disposer =>
          scope.own(core.keymap.bind(spec, lookup(command), options?.in === undefined ? {} : { in: options.in })),
      ),
      pending: live((): string => core.keymap.pending()),
      keysOf: live((name: string): readonly string[] => core.keymap.keysOf(lookup(name))),
    }),
    styles: Object.freeze({
      set: live((name: string, patch: StylePatch): Disposer => scope.own(core.styles.set(name, patch))),
    }),
    notices: Object.freeze({
      list: live((): readonly Notice[] => core.notices.list()),
      on: live((listener: (notice: Notice) => void): Disposer => scope.own(core.notices.on(listener))),
    }),
    views: Object.freeze({
      register: live((type: string, restore: RestoreView): Disposer => {
        if (typeof restore !== "function") throw new TypeError("a view type takes a function that restores its view");
        return scope.own(core.views.register(own(type), { owner, restore, adopt: (mount) => scope.ownMount(mount) }));
      }),
    }),
    requestFrame: live((delay?: number): void => core.driver.requestFrame(delay)),
    copy: live((text: string): void => core.driver.copy(String(text))),
  });
}
