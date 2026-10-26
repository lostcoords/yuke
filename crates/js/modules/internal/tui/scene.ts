/**
 * The scene: the root view and the overlays above it, the tree of placed views of each layer, the focus path, input
 * routing, the mouse capture, drawing, and the fault boundary of each view callback.
 */
import { failureOf } from "yuke:internal/failure";
import { createCanvas, type DrawCall, intersect, type Screen } from "yuke:internal/tui/canvas";
import { createMount, startView } from "yuke:internal/tui/mount";
import type {
  KeyEvent,
  Mount,
  MouseButton,
  MouseEvent,
  OverlayOptions,
  Point,
  Rect,
  Size,
  View,
  ViewFactory,
} from "yuke:tui";

/** What the scene needs from the core. */
export interface SceneHost {
  readonly screen: Screen;
  readonly size: () => Size;
  readonly cursor: (point: Point | undefined) => void;
  readonly requestFrame: () => void;
  /** Report a fault of a callback of `source` (a plugin name or `core`). */
  readonly report: (source: string, text: string) => void;
  /** True for a view that takes the focus without `focusable`, such as the view of a pane. */
  readonly focusableByRole: (view: View) => boolean;
  /** The root focus when the focused view left the tree, such as the view of the active pane. */
  readonly fallbackFocus: () => View | undefined;
  /** The focus path changed: the views of the root layer, from the root down, even under a modal. */
  readonly focusMoved: (rootPath: readonly View[]) => void;
}

/** A placed view: its rect and clip in screen cells, its parent, and its children. */
interface Target {
  readonly view: View;
  readonly owner: string;
  readonly parent: Target | undefined;
  readonly rect: Rect;
  readonly clip: Rect;
  readonly children: Target[];
}

interface Layer {
  readonly view: View;
  readonly owner: string;
  readonly mount: Mount;
  readonly modal: boolean;
  readonly place: ((size: Size) => Rect) | undefined;
  /** The focused view of an overlay. The root layer keeps its focus in the scene, across a change of the root. */
  focus: View | undefined;
  tree: Target | undefined;
}

const NO_MOUNT: Mount = Object.freeze({ close(): void {}, signal: AbortSignal.abort() });
const ERROR_STYLE = Object.freeze({ fg: "danger" as const });

export class Scene {
  readonly #host: SceneHost;
  readonly #defaultRoot: Layer;
  #root: Layer;
  readonly #overlays: Layer[] = [];
  #rootFocus: View | undefined;
  /** The text of the first fault of each failed view. A failed view draws it until the view goes. */
  readonly #failed = new WeakMap<View, string>();
  /** The last focused view inside each view of the focus path, so a refocus of a pane finds its composer again. */
  readonly #lastInside = new WeakMap<View, View>();
  #capture: { readonly view: View; readonly owner: string; readonly button: MouseButton; point: Point } | undefined;
  /** The focus path of the input layer at the last layout. Its targets reach a view that left the tree since. */
  #path: readonly Target[] = [];
  /** The views of the root focus path at the last layout, also under a modal. */
  #rootPath: readonly View[] = [];

  /** `root` is the default root view, owned by the core: the root again after the close of each other root. */
  constructor(host: SceneHost, root: View) {
    this.#host = host;
    this.#defaultRoot = {
      view: root,
      owner: "core",
      mount: NO_MOUNT,
      modal: false,
      place: undefined,
      focus: undefined,
      tree: undefined,
    };
    this.#root = this.#defaultRoot;
  }

  /** Make the root view with `create`. The close of the mount gives the default root back; a newer root closes it. */
  setRoot(owner: string, create: ViewFactory): Mount {
    let layer: Layer | undefined;
    const mount = createMount(() => {
      if (layer !== undefined && this.#root === layer) this.#root = this.#defaultRoot;
      this.#changed();
    });
    const view = startView(owner, create, mount, this.#host.report);
    if (view === undefined) return mount;
    layer = { view, owner, mount, modal: false, place: undefined, focus: undefined, tree: undefined };
    const old = this.#root;
    this.#root = layer;
    old.mount.close();
    this.#changed();
    return mount;
  }

  /** Make an overlay with `create` above the root and the other overlays. A modal ends the mouse capture. */
  overlay(owner: string, create: ViewFactory, options: OverlayOptions = {}): Mount {
    const { modal = true, place } = options;
    if (place !== undefined && typeof place !== "function") throw new TypeError("place is a function of the size");
    let layer: Layer | undefined;
    const mount = createMount(() => {
      const at = layer === undefined ? -1 : this.#overlays.indexOf(layer);
      if (at >= 0) this.#overlays.splice(at, 1);
      this.#changed();
    });
    const view = startView(owner, create, mount, this.#host.report);
    if (view === undefined) return mount;
    layer = { view, owner, mount, modal: modal !== false, place, focus: undefined, tree: undefined };
    if (layer.modal) this.cancelCapture();
    this.#overlays.push(layer);
    this.#changed();
    return mount;
  }

  /** Place the views of each layer at the size of the screen. Input and drawing need it first. */
  layout(): void {
    const size = this.#host.size();
    const screen = { column: 0, row: 0, width: size.width, height: size.height };
    this.#root.tree = this.#place(this.#root.view, this.#root.owner, screen, screen, undefined, new Set());
    for (const layer of this.#overlays) {
      const rect = layer.place === undefined ? screen : this.#placeOverlay(layer, size, screen);
      layer.tree = this.#place(layer.view, layer.owner, rect, rect, undefined, new Set());
    }
    // A captured view that left the tree gets its `cancel` now: no release can reach it.
    if (this.#capture !== undefined && this.#find(this.#capture.view) === undefined) this.cancelCapture();
    this.#syncFocus();
  }

  /** Draw the root tree, then each overlay over a blank rect, then the cursor of the focused view. */
  draw(): void {
    const focused = new Set(this.#path.map((target) => target.view));
    if (this.#root.tree !== undefined) this.#drawTarget(this.#root.tree, focused);
    for (const layer of this.#overlays) {
      if (layer.tree === undefined) continue;
      const { rect } = layer.tree;
      this.#host.screen.fill(rect.column, rect.row, rect.width, rect.height, this.#host.screen.resolve(undefined));
      this.#drawTarget(layer.tree, focused);
    }
    this.#host.cursor(this.#cursor());
  }

  /** Give `event` to the floats above the input layer, then along the focus path from the deepest view up. */
  key(event: KeyEvent): boolean {
    for (const layer of this.#floatsOnTop()) {
      if (this.#bubble(layer, (view) => view.key, event)) return true;
    }
    return this.#bubble(this.#inputLayer(), (view) => view.key, event);
  }

  /** Give a paste along the focus path of the input layer. */
  paste(text: string): boolean {
    return this.#bubble(this.#inputLayer(), (view) => view.paste, text);
  }

  /**
   * Route a mouse event in screen cells. A drag or a release goes to the captured view first, also under a float, so
   * a drag ends where it started; a modal that opens ends the capture. Else the overlays from the top get it (a modal
   * takes each event; a float takes what it handles inside its rect), then the root.
   */
  mouse(event: MouseEvent): void {
    const capture = this.#capture;
    if (capture !== undefined && (event.action === "drag" || event.action === "release")) {
      const target = this.#find(capture.view);
      if (target === undefined) {
        this.cancelCapture();
        return;
      }
      capture.point = { column: event.column, row: event.row };
      this.#call(target, false, () => target.view.mouse?.(local(event, target)) === true);
      if (event.action === "release") this.#capture = undefined;
      return;
    }
    for (const layer of this.#overlays.toReversed()) {
      if (layer.tree === undefined) continue;
      if (layer.modal) {
        this.#route(layer, event);
        return;
      }
      // A float routes only inside its rect: the hit test stops at the clip of its tree.
      if (this.#route(layer, event)) return;
    }
    this.#route(this.#root, event);
  }

  /** End the mouse capture without a release: the captured view gets `action: "cancel"`, also when it left the tree. */
  cancelCapture(): void {
    const capture = this.#capture;
    if (capture === undefined) return;
    this.#capture = undefined;
    const target = this.#find(capture.view);
    const event: MouseEvent = {
      type: "mouse",
      column: capture.point.column,
      row: capture.point.row,
      button: capture.button,
      action: "cancel",
      modifiers: { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false },
    };
    const delivered = target === undefined ? event : local(event, target);
    this.#call(capture, false, () => capture.view.mouse?.(delivered) === true);
  }

  /** Close the top overlay when it is a modal, as for an Escape that nothing took. */
  closeTopModal(): boolean {
    const top = this.#overlays.at(-1);
    if (top === undefined || !top.modal) return false;
    top.mount.close();
    return true;
  }

  /** Give the focus to `view` when it is placed and focusable. A view of the root keeps it beneath a modal. */
  focus(view: View): boolean {
    for (const layer of [this.#root, ...this.#overlays]) {
      const target = layer.tree === undefined ? undefined : findIn(layer.tree, view);
      if (target === undefined) continue;
      if (!this.#focusable(view)) return false;
      this.#setFocus(layer, this.#remembered(target).view);
      return true;
    }
    return false;
  }

  /** Make `view` the root focus, also before its first layout, as for a new pane. Its remembered inner focus wins. */
  focusRoot(view: View): void {
    this.#rootFocus = view;
    this.#changed();
  }

  /** The deepest view on the focus path of the input layer. */
  get focused(): View | undefined {
    return this.#path.at(-1)?.view;
  }

  /** The context atoms of the keymap: `global`, `root` or `overlay`, then the contexts along the focus path. */
  atoms(): string[] {
    const atoms = ["global", this.#inputLayer() === this.#root ? "root" : "overlay"];
    for (const target of this.#path) {
      const contexts = this.#call(target, undefined, () => target.view.contexts);
      if (Array.isArray(contexts)) atoms.push(...contexts.filter((atom) => typeof atom === "string"));
    }
    return atoms;
  }

  #placeOverlay(layer: Layer, size: Size, screen: Rect): Rect {
    const target = { view: layer.view, owner: layer.owner };
    const rect = this.#call(target, screen, () => layer.place?.(size) ?? screen);
    return isRect(rect) ? intersect(screen, rect) : screen;
  }

  /** The target of `view` at `rect`, cut to `clip`, with its placed children. A view placed twice keeps its first place. */
  #place(view: View, owner: string, rect: Rect, clip: Rect, parent: Target | undefined, seen: Set<View>): Target {
    const target: Target = { view, owner, parent, rect, clip, children: [] };
    seen.add(view);
    if (view.layout === undefined) return target;
    const placements = this.#call(target, [], () => view.layout?.({ width: rect.width, height: rect.height }) ?? []);
    if (!Array.isArray(placements)) return target;
    for (const placement of placements) {
      const child: unknown = placement?.view;
      if (typeof child !== "object" || child === null || seen.has(child as View) || !isRect(placement.rect)) continue;
      const childRect = {
        column: rect.column + placement.rect.column,
        row: rect.row + placement.rect.row,
        width: Math.max(0, placement.rect.width),
        height: Math.max(0, placement.rect.height),
      };
      target.children.push(this.#place(child as View, owner, childRect, intersect(clip, childRect), target, seen));
    }
    return target;
  }

  #drawTarget(target: Target, focused: Set<View>): void {
    const call: DrawCall = { open: true };
    const canvas = createCanvas(this.#host.screen, target.rect, target.clip, call);
    const failure = this.#failed.get(target.view);
    if (failure === undefined) {
      this.#call(target, undefined, () => target.view.draw(canvas, focused.has(target.view)));
    }
    const shown = this.#failed.get(target.view);
    if (shown !== undefined) {
      canvas.fill(0, 0, canvas.width, canvas.height);
      canvas.text(0, 0, `${target.owner}: ${shown.split("\n")[0] ?? ""}`, ERROR_STYLE);
    }
    call.open = false;
    if (shown === undefined) for (const child of target.children) this.#drawTarget(child, focused);
  }

  /** Run `f`, a callback of `view` of `owner`, inside the fault boundary of the view. A fault gives `fallback`. */
  guard<T>(view: View, owner: string, fallback: T, f: () => T): T {
    return this.#call({ view, owner }, fallback, f);
  }

  /**
   * Run a callback of the view of `target`. The first throw, or a returned promise, marks the view failed and reports
   * once; a failed view gets no more calls, and its rect draws the error until the view goes.
   */
  #call<T>(target: { readonly view: View; readonly owner: string }, fallback: T, f: () => T): T {
    if (this.#failed.has(target.view)) return fallback;
    try {
      const result = f();
      if (typeof (result as { then?: unknown } | undefined)?.then === "function") {
        throw new TypeError("a view callback returned a promise: view callbacks are synchronous");
      }
      return result;
    } catch (error) {
      const text = failureOf(error);
      this.#failed.set(target.view, text);
      this.#host.report(target.owner, text);
      this.#changed();
      return fallback;
    }
  }

  /** Give `value` to the handler of each view on the focus path of `layer`, from the deepest view up. */
  #bubble<A>(layer: Layer, handler: (view: View) => ((value: A) => boolean) | undefined, value: A): boolean {
    for (let target = this.#focusTarget(layer); target !== undefined; target = target.parent) {
      const { view } = target;
      if (handler(view) === undefined) continue;
      if (this.#call(target, false, () => handler(view)?.call(view, value) === true)) return true;
    }
    return false;
  }

  /** Route a mouse event inside `layer`: a press focuses; the deepest view under the pointer gets it first. */
  #route(layer: Layer, event: MouseEvent): boolean {
    if (layer.tree === undefined) return false;
    const hit = deepest(layer.tree, event);
    if (hit === undefined) return false;
    const wheel = event.button.startsWith("wheel_");
    const input = this.#inputLayer();
    if (event.action === "press" && !wheel) {
      for (let target: Target | undefined = hit; target !== undefined; target = target.parent) {
        if (this.#focusable(target.view)) {
          this.#setFocus(layer, target.view);
          break;
        }
      }
    }
    for (let target: Target | undefined = hit; target !== undefined; target = target.parent) {
      const current = target;
      const { view } = current;
      if (view.mouse === undefined) continue;
      if (this.#call(current, false, () => view.mouse?.(local(event, current)) === true)) {
        // A handler that opened a modal gave the input away, so it gets no capture.
        if (event.action === "press" && event.button === "left" && this.#inputLayer() === input) {
          const point = { column: event.column, row: event.row };
          this.#capture = { view, owner: current.owner, button: event.button, point };
        }
        return true;
      }
    }
    return false;
  }

  #setFocus(layer: Layer, view: View): void {
    if (layer === this.#root || layer === this.#defaultRoot) this.#rootFocus = view;
    else layer.focus = view;
    this.#syncFocus();
    this.#changed();
  }

  /** The focused target of `layer`, or a fallback when its focused view left the tree. */
  #focusTarget(layer: Layer): Target | undefined {
    if (layer.tree === undefined) return undefined;
    const isRoot = layer === this.#root;
    const wanted = isRoot ? this.#rootFocus : layer.focus;
    const found = wanted === undefined ? undefined : findIn(layer.tree, wanted);
    if (found !== undefined) return this.#remembered(found);
    const fallback = isRoot ? this.#host.fallbackFocus() : undefined;
    const fallen = fallback === undefined ? undefined : findIn(layer.tree, fallback);
    return fallen === undefined ? layer.tree : this.#remembered(fallen);
  }

  /** The last focused view inside `target`, when it is still in the subtree of `target`. */
  #remembered(target: Target): Target {
    const inner = this.#lastInside.get(target.view);
    return (inner === undefined ? undefined : findIn(target, inner)) ?? target;
  }

  /**
   * Compare the focus paths with the last ones: each view that leaves or enters the input path gets `focusChanged`,
   * and a change of either path reaches the host, as a focus change of the root beneath a modal.
   */
  #syncFocus(): void {
    const path = targetsTo(this.#focusTarget(this.#inputLayer()));
    const rootPath = targetsTo(this.#focusTarget(this.#root)).map((target) => target.view);
    const before = this.#path;
    const rootBefore = this.#rootPath;
    this.#path = path;
    this.#rootPath = rootPath;
    const deepest = path.at(-1)?.view;
    for (const { view } of path) this.#lastInside.set(view, deepest ?? view);
    const views = path.map((target) => target.view);
    const viewsBefore = before.map((target) => target.view);
    const inputChanged = !sameViews(views, viewsBefore);
    if (inputChanged) {
      for (const target of before) if (!views.includes(target.view)) this.#notifyFocus(target, false);
      for (const target of path) if (!viewsBefore.includes(target.view)) this.#notifyFocus(target, true);
    }
    if (inputChanged || !sameViews(rootPath, rootBefore)) this.#host.focusMoved(rootPath);
  }

  /** Tell the view of `target` its focus change. A target of an earlier layout reaches a view that left the tree. */
  #notifyFocus(target: Target, focused: boolean): void {
    if (target.view.focusChanged === undefined) return;
    this.#call(target, undefined, () => target.view.focusChanged?.(focused));
  }

  #focusable(view: View): boolean {
    return view.focusable === true || this.#host.focusableByRole(view);
  }

  /** The top modal, else the root. */
  #inputLayer(): Layer {
    return this.#overlays.findLast((layer) => layer.modal) ?? this.#root;
  }

  /** The floats above the input layer, the top first. */
  #floatsOnTop(): Layer[] {
    const floats: Layer[] = [];
    for (const layer of this.#overlays.toReversed()) {
      if (layer.modal) break;
      floats.push(layer);
    }
    return floats;
  }

  #find(view: View): Target | undefined {
    for (const layer of [this.#root, ...this.#overlays]) {
      const target = layer.tree === undefined ? undefined : findIn(layer.tree, view);
      if (target !== undefined) return target;
    }
    return undefined;
  }

  #cursor(): Point | undefined {
    const target = this.#focusTarget(this.#inputLayer());
    if (target === undefined || target.view.cursor === undefined) return undefined;
    const point = this.#call(target, undefined, () => target.view.cursor?.());
    if (point === undefined || !Number.isFinite(point.column) || !Number.isFinite(point.row)) return undefined;
    const screen = {
      column: target.rect.column + Math.floor(point.column),
      row: target.rect.row + Math.floor(point.row),
    };
    return inside(target.clip, screen) ? screen : undefined;
  }

  #changed(): void {
    this.#host.requestFrame();
  }
}

function findIn(target: Target, view: View): Target | undefined {
  if (target.view === view) return target;
  for (const child of target.children) {
    const found = findIn(child, view);
    if (found !== undefined) return found;
  }
  return undefined;
}

/** The deepest target under `point`, inside its clip. A later child lies over an earlier one. */
function deepest(target: Target, point: Point): Target | undefined {
  if (!inside(target.clip, point)) return undefined;
  for (const child of target.children.toReversed()) {
    const found = deepest(child, point);
    if (found !== undefined) return found;
  }
  return target;
}

/** The targets from the root of the tree down to `target`. */
function targetsTo(target: Target | undefined): Target[] {
  const path: Target[] = [];
  for (let at = target; at !== undefined; at = at.parent) path.unshift(at);
  return path;
}

function sameViews(a: readonly View[], b: readonly View[]): boolean {
  return a.length === b.length && a.every((view, at) => b[at] === view);
}

function inside(rect: Rect, point: Point): boolean {
  return (
    point.column >= rect.column &&
    point.column < rect.column + rect.width &&
    point.row >= rect.row &&
    point.row < rect.row + rect.height
  );
}

function local(event: MouseEvent, target: Target): MouseEvent {
  return { ...event, column: event.column - target.rect.column, row: event.row - target.rect.row };
}

function isRect(value: unknown): value is Rect {
  if (typeof value !== "object" || value === null) return false;
  const { column, row, width, height } = value as Rect;
  return [column, row, width, height].every((number) => Number.isInteger(number));
}
