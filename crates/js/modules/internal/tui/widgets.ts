/**
 * The text widgets of the core: the extension support that each widget owns, and the mounts of the placed widgets. A
 * widget registers its support with `registerWidget`. Each layout publishes the placed widgets, and each watch gets
 * each mount once.
 */
import { failureOf } from "yuke:internal/failure";
import type {
  CursorShape,
  Decoration,
  Disposer,
  KeyEvent,
  MouseEvent,
  Pane,
  TextAppearance,
  TextEditor,
  TextExtension,
  TextView,
  View,
  WidgetMount,
} from "yuke:tui";

/** What a placed widget asks of the core. */
export interface WidgetHost {
  readonly requestFrame: () => void;
  /** The context atoms of an extension changed, so a pending key sequence ends. */
  readonly contextsChanged: () => void;
  /** Report a fault of an extension. */
  readonly report: (text: string) => void;
  /** Send `text` to the clipboard of the terminal. */
  readonly copy: (text: string) => void;
}

type KeyPhase = "beforeDefault" | "beforeKeymap";

const SHAPES: readonly unknown[] = ["block", "underline", "bar"] satisfies CursorShape[];
const PHASES: readonly unknown[] = ["beforeDefault", "beforeKeymap"] satisfies KeyPhase[];

/** The part of one extension, and its dispose. */
interface Part<P> {
  contexts: readonly string[];
  appearance: TextAppearance;
  decorations: readonly Decoration<P>[];
  disposed: boolean;
  dispose: () => void;
}

interface Handler<P, T> {
  readonly part: Part<P>;
  readonly handle: T;
}

/**
 * The extensions of one text widget, with positions `P` and change events `E`. The widget draws with `appearance`
 * and `decorations`, and adds `contexts` to its own. It calls `key(event, "beforeDefault")`, `mouse`, and `paste`
 * before its own handling. It gives each change to `emit`.
 */
export class TextSupport<P, E> {
  /** The group of related widgets, such as a composer and its transcript. */
  readonly group: object;
  #host: WidgetHost | undefined;
  /** The parts in the order of their extensions. */
  readonly #parts: Part<P>[] = [];
  readonly #keys: Record<KeyPhase, Handler<P, (event: KeyEvent) => boolean>[]> = {
    beforeKeymap: [],
    beforeDefault: [],
  };
  readonly #mice: Handler<P, (event: MouseEvent) => boolean>[] = [];
  readonly #pastes: Handler<P, (text: string) => boolean>[] = [];
  readonly #listeners: Handler<P, (event: E) => void>[] = [];

  /** Without `group` the widget gets a group of its own. */
  constructor(group: object | undefined) {
    if (group !== undefined && (typeof group !== "object" || group === null)) {
      throw new TypeError("a widget group is an object");
    }
    this.group = group ?? {};
  }

  /** The core of the placed widget, or `undefined` when it leaves the tree. */
  attach(host: WidgetHost | undefined): void {
    this.#host = host;
  }

  /** A new extension. The abort of `signal` disposes it. With an aborted signal, each call of it does nothing. */
  extend(signal: AbortSignal): TextExtension<P, E> {
    const part: Part<P> = {
      contexts: [],
      appearance: {},
      decorations: [],
      disposed: signal.aborted,
      dispose: () => {
        if (part.disposed) return;
        part.disposed = true;
        signal.removeEventListener("abort", part.dispose);
        this.#parts.splice(this.#parts.indexOf(part), 1);
        const ours = (handler: { readonly part: Part<P> }): boolean => handler.part === part;
        removeWhere(this.#keys.beforeKeymap, ours);
        removeWhere(this.#keys.beforeDefault, ours);
        removeWhere(this.#mice, ours);
        removeWhere(this.#pastes, ours);
        removeWhere(this.#listeners, ours);
        if (part.contexts.length > 0) this.#host?.contextsChanged();
        this.#host?.requestFrame();
      },
    };
    if (!part.disposed) {
      this.#parts.push(part);
      signal.addEventListener("abort", part.dispose, { once: true });
    }
    const add = <T>(list: Handler<P, T>[], handle: T, kind: string): Disposer => {
      if (typeof handle !== "function") throw new TypeError(`a ${kind} handler is a function`);
      if (part.disposed) return () => {};
      const handler = { part, handle };
      list.push(handler);
      return () => removeWhere(list, (entry) => entry === handler);
    };
    return Object.freeze({
      setContexts: (atoms: readonly string[]): void => {
        if (!Array.isArray(atoms) || !atoms.every((atom) => typeof atom === "string" && atom !== "")) {
          throw new TypeError("contexts are strings that are not empty");
        }
        if (part.disposed) return;
        part.contexts = Object.freeze([...atoms]);
        this.#host?.contextsChanged();
        this.#host?.requestFrame();
      },
      setAppearance: (appearance: TextAppearance): void => {
        const checked = checkAppearance(appearance);
        if (part.disposed) return;
        part.appearance = checked;
        this.#host?.requestFrame();
      },
      setDecorations: (decorations: readonly Decoration<P>[]): void => {
        const valid =
          Array.isArray(decorations) &&
          decorations.every(
            (decoration) =>
              typeof decoration?.range === "object" && decoration.range !== null && isStyle(decoration.style, false),
          );
        if (!valid) throw new TypeError("a decoration has a range and a style");
        if (part.disposed) return;
        part.decorations = Object.freeze(decorations.map((decoration) => Object.freeze({ ...decoration })));
        this.#host?.requestFrame();
      },
      onKey: (handler: (event: KeyEvent) => boolean, phase: KeyPhase = "beforeDefault"): Disposer => {
        if (!PHASES.includes(phase)) throw new TypeError(`a key phase is beforeDefault or beforeKeymap, not ${phase}`);
        return add(this.#keys[phase], handler, "key");
      },
      onMouse: (handler: (event: MouseEvent) => boolean): Disposer => add(this.#mice, handler, "mouse"),
      onPaste: (handler: (text: string) => boolean): Disposer => add(this.#pastes, handler, "paste"),
      onChange: (listener: (event: E) => void): Disposer => add(this.#listeners, listener, "change"),
      dispose: part.dispose,
    });
  }

  /** Ask the core for a frame after a change of the widget. Before the widget is placed, do nothing. */
  requestFrame(): void {
    this.#host?.requestFrame();
  }

  /** Send `text` to the clipboard. Before the widget is placed, do nothing. */
  copy(text: string): void {
    this.#host?.copy(text);
  }

  /** The context atoms of the extensions, in the order of the extensions. */
  contexts(): string[] {
    return this.#parts.flatMap((part) => part.contexts);
  }

  /** `base` with the fields of each extension over it, the newest last. */
  appearance(base: TextAppearance = {}): TextAppearance {
    return Object.assign({}, base, ...this.#parts.map((part) => part.appearance));
  }

  /** The decorations of the extensions, the newest last, so a widget that draws them in order lets the newest win. */
  decorations(): Decoration<P>[] {
    return this.#parts.flatMap((part) => part.decorations);
  }

  /** Give a key to the handlers of `phase`, the newest first. `true` when one takes it. */
  key(event: KeyEvent, phase: KeyPhase): boolean {
    return this.#offer(this.#keys[phase], event);
  }

  mouse(event: MouseEvent): boolean {
    return this.#offer(this.#mice, event);
  }

  paste(text: string): boolean {
    return this.#offer(this.#pastes, text);
  }

  /** Give a change to each listener, the oldest first. */
  emit(event: E): void {
    for (const listener of [...this.#listeners]) this.#guard(listener.part, () => listener.handle(event));
  }

  #offer<T>(list: Handler<P, (value: T) => boolean>[], value: T): boolean {
    return list
      .toReversed()
      .some((handler) => this.#guard(handler.part, () => handler.handle(value) === true) === true);
  }

  /** Run a callback of the extension of `part`. When it throws, report the fault and remove the extension. */
  #guard<T>(part: Part<P>, f: () => T): T | undefined {
    if (part.disposed) return undefined;
    try {
      return f();
    } catch (error) {
      const text = `a text widget extension failed and was removed: ${failureOf(error)}`;
      if (this.#host === undefined) reportError(new Error(text));
      else this.#host.report(text);
      part.dispose();
      return undefined;
    }
  }
}

/** A hosted view at its place: its pane and the layer that holds it. */
export interface PlacedView {
  readonly view: View;
  readonly pane: Pane | undefined;
  readonly layer: object;
}

/** What the core reads of the support of a widget, whatever its positions and events. */
interface WidgetSupport {
  readonly group: object;
  attach: (host: WidgetHost | undefined) => void;
  key: (event: KeyEvent, phase: KeyPhase) => boolean;
}

/** The views that can take a host while they are placed, such as a widget that asks for a frame after a change. */
const hosts = new WeakMap<View, (host: WidgetHost | undefined) => void>();

/** The core calls `attach` with its host when a layout places `view`, and with `undefined` when the view leaves. */
export function registerHost(view: View, attach: (host: WidgetHost | undefined) => void): void {
  hosts.set(view, attach);
}

export function isHosted(view: View): boolean {
  return hosts.has(view);
}

/** Give `host` to `view`, for a view that a parent draws itself, such as the list inside a text view. */
export function attachHost(view: View, host: WidgetHost | undefined): void {
  hosts.get(view)?.(host);
}

/** The text widgets and their support. A widget registers itself in its constructor. */
const registered = new WeakMap<View, { readonly widget: TextEditor | TextView; readonly support: WidgetSupport }>();

export function registerWidget(widget: TextEditor | TextView, support: WidgetSupport): void {
  registered.set(widget, { widget, support });
  registerHost(widget, (host) => support.attach(host));
}

export function supportOf(view: View): WidgetSupport | undefined {
  return registered.get(view)?.support;
}

interface Mounted {
  readonly mount: WidgetMount;
  readonly controller: AbortController;
  readonly layer: object;
}

interface Watch {
  readonly owner: string;
  readonly attach: (mount: WidgetMount) => Disposer | undefined;
  /** Each mount that the watch saw, with its cleanup when `attach` gave one. */
  readonly cleanups: Map<WidgetMount, Disposer | undefined>;
}

/** The core host of each placed hosted view, and the mounts of the placed text widgets. */
export class WidgetMounts {
  readonly #host: WidgetHost;
  readonly #report: (source: string, text: string) => void;
  /** The views that hold the host now. */
  readonly #hosted = new Set<View>();
  readonly #mounted = new Map<View, Mounted>();
  readonly #watches = new Set<Watch>();

  constructor(host: WidgetHost, report: (source: string, text: string) => void) {
    this.#host = host;
    this.#report = report;
  }

  /**
   * Publish the hosted views of a layout. A view that leaves loses the host, and a new one gets it. A widget that stays
   * in its pane and layer keeps its mount, also under a modal. The mounts of the widgets that leave or move end first.
   * Then each watch gets each new mount.
   */
  update(placed: readonly PlacedView[]): void {
    const now = new Map(placed.map((entry) => [entry.view, entry]));
    for (const view of [...this.#hosted]) {
      if (now.has(view)) continue;
      this.#hosted.delete(view);
      hosts.get(view)?.(undefined);
    }
    for (const view of now.keys()) {
      if (this.#hosted.has(view)) continue;
      this.#hosted.add(view);
      hosts.get(view)?.(this.#host);
    }
    for (const [view, mounted] of [...this.#mounted]) {
      const entry = now.get(view);
      if (entry !== undefined && entry.pane === mounted.mount.pane && entry.layer === mounted.layer) continue;
      this.#mounted.delete(view);
      mounted.controller.abort();
      for (const watch of this.#watches) {
        const cleanup = watch.cleanups.get(mounted.mount);
        watch.cleanups.delete(mounted.mount);
        if (cleanup !== undefined) this.#run(watch.owner, cleanup);
      }
    }
    const added: WidgetMount[] = [];
    for (const entry of now.values()) {
      const found = registered.get(entry.view);
      if (found === undefined || this.#mounted.has(entry.view)) continue;
      const controller = new AbortController();
      const mount = Object.freeze({
        widget: found.widget,
        pane: entry.pane,
        group: found.support.group,
        signal: controller.signal,
      });
      this.#mounted.set(entry.view, { mount, controller, layer: entry.layer });
      added.push(mount);
    }
    for (const mount of added) {
      for (const watch of [...this.#watches]) this.#visit(watch, mount);
    }
  }

  list(): WidgetMount[] {
    return [...this.#mounted.values()].map((mounted) => mounted.mount);
  }

  /** Give `attach` the current mounts, then each new mount. Run a cleanup when its mount leaves or the watch ends. */
  watch(owner: string, attach: (mount: WidgetMount) => Disposer | undefined): Disposer {
    if (typeof attach !== "function") throw new TypeError("a widget watch takes a function");
    const watch: Watch = { owner, attach, cleanups: new Map() };
    this.#watches.add(watch);
    for (const mount of this.list()) this.#visit(watch, mount);
    return () => {
      if (!this.#watches.delete(watch)) return;
      for (const cleanup of watch.cleanups.values()) if (cleanup !== undefined) this.#run(owner, cleanup);
      watch.cleanups.clear();
    };
  }

  #visit(watch: Watch, mount: WidgetMount): void {
    // A watch that starts inside an attach sees the mounts of the running update already.
    if (!this.#watches.has(watch) || mount.signal.aborted || watch.cleanups.has(mount)) return;
    watch.cleanups.set(mount, undefined);
    try {
      const cleanup = watch.attach(mount);
      if (typeof cleanup === "function") watch.cleanups.set(mount, cleanup);
    } catch (error) {
      this.#report(watch.owner, `a widget watch failed: ${failureOf(error)}`);
    }
  }

  #run(owner: string, cleanup: Disposer): void {
    try {
      cleanup();
    } catch (error) {
      this.#report(owner, `a widget cleanup failed: ${failureOf(error)}`);
    }
  }
}

/** A frozen copy of `appearance`, with its fields checked. */
export function checkAppearance(appearance: TextAppearance): TextAppearance {
  if (typeof appearance !== "object" || appearance === null) throw new TypeError("an appearance is an object");
  if (appearance.cursorShape !== undefined && !SHAPES.includes(appearance.cursorShape)) {
    throw new TypeError(`a cursor shape is block, underline, or bar, not ${String(appearance.cursorShape)}`);
  }
  if (appearance.prompt !== undefined && typeof appearance.prompt !== "string") {
    throw new TypeError("a prompt is a string");
  }
  if (!isStyle(appearance.promptStyle, true)) throw new TypeError("a prompt style is a style name or a style");
  return Object.freeze({ ...appearance });
}

function isStyle(value: unknown, optional: boolean): boolean {
  if (value === undefined) return optional;
  return typeof value === "string" || (typeof value === "object" && value !== null);
}

function removeWhere<T>(list: T[], matches: (item: T) => boolean): void {
  for (let at = list.length - 1; at >= 0; at -= 1) if (matches(list[at] as T)) list.splice(at, 1);
}
