/**
 * The scene holds the roots, the overlays, the placed views, the focus path, and the mouse capture. It routes the
 * input and draws.
 */
import { createCanvas, intersect, layered, type Screen } from "yuke:internal/tui/canvas";
import { createMount, startView } from "yuke:internal/tui/mount";
import { isHosted, type PlacedView, supportOf } from "yuke:internal/tui/widgets";
import type {
  CanvasStyle,
  Cursor,
  FocusChange,
  KeyEvent,
  Mount,
  MouseButton,
  MouseEvent,
  OverlayOptions,
  Pane,
  Point,
  Rect,
  RootFactory,
  Size,
  View,
  ViewFactory,
} from "yuke:tui";

/** What the scene needs from the core. */
interface SceneHost {
  readonly screen: Screen;
  readonly size: () => Size;
  readonly cursor: (cursor: Cursor | undefined) => void;
  readonly requestFrame: () => void;
  /** Report a fault of a view factory of `source` (a plugin name or `core`). */
  readonly report: (source: string, text: string) => void;
  /** The handle of the view of a pane, or `undefined` for another view. A pane takes the focus. */
  readonly paneOf: (view: View) => PaneLeaf | undefined;
  /** The root focus when the focused view left the tree, such as the view of the active pane. */
  readonly fallbackFocus: () => View | undefined;
  /**
   * The focus path changed: the views of the root layer, from the root down, even under a modal. `change` is set when
   * the deepest view of the input path changed.
   */
  readonly focusMoved: (rootPath: readonly View[], change: FocusChange | undefined) => void;
  /** The hosted views of a layout, such as the text widgets, before its focus resolves. */
  readonly placed: (views: readonly PlacedView[]) => void;
}

/** The handle of a pane, or `undefined` for an empty pane. */
interface PaneLeaf {
  readonly pane: Pane | undefined;
}

/** A placed view: its rect and clip in screen cells, its pane, its parent, and its children. */
interface Target {
  readonly view: View;
  readonly pane: Pane | undefined;
  readonly parent: Target | undefined;
  readonly rect: Rect;
  readonly clip: Rect;
  readonly children: Target[];
}

interface Layer {
  readonly view: View;
  /** The focused view of an overlay. The root layer keeps its focus in the scene, across a change of the root. */
  focus: View | undefined;
  tree: Target | undefined;
}

interface Overlay extends Layer {
  readonly mount: Mount;
  readonly modal: boolean;
  readonly place: ((size: Size) => Rect) | undefined;
}

/** The layer of each hosted view of a root. All roots count as one, so a wrap or a close keeps a widget mount. */
const ROOTS = {};

export class Scene {
  readonly #host: SceneHost;
  /** The roots from the bottom up. The root of the core stays first. Each other root places the root below it. */
  readonly #roots: Layer[];
  readonly #overlays: Overlay[] = [];
  #rootFocus: View | undefined;
  /** The last focused view inside each view of the focus path, so a refocus of a pane finds its composer again. */
  readonly #lastInside = new WeakMap<View, View>();
  #capture: { readonly view: View; readonly button: MouseButton; point: Point } | undefined;
  /** The focus path of the input layer at the last layout. Its targets reach a view that left the tree since. */
  #path: readonly Target[] = [];
  /** The views of the root focus path at the last layout, also under a modal. */
  #rootPath: readonly View[] = [];

  /** `root` is the view of the core. It stays below each other root. */
  constructor(host: SceneHost, root: View) {
    this.#host = host;
    this.#roots = [{ view: root, focus: undefined, tree: undefined }];
  }

  get #root(): Layer {
    return this.#roots.at(-1) as Layer;
  }

  /** Make a root with `create` around the current root. The close of the mount removes only this root. */
  wrapRoot(owner: string, create: RootFactory): Mount {
    if (typeof create !== "function") throw new TypeError("a root takes a function that makes its view");
    let layer: Layer | undefined;
    const mount = createMount(() => {
      if (layer !== undefined) this.#roots.splice(this.#roots.indexOf(layer), 1);
      this.#host.requestFrame();
    });
    // A root in the middle can close, so `inner` finds the root below at each layout.
    const inner: View = {
      layout: (size) => {
        const below = layer === undefined ? undefined : this.#roots[this.#roots.indexOf(layer) - 1];
        if (below === undefined) return [];
        return [{ view: below.view, rect: { column: 0, row: 0, width: size.width, height: size.height } }];
      },
      draw(): void {},
    };
    const view = startView(owner, (own) => create(own, inner), mount, this.#host.report);
    if (view === undefined) return mount;
    layer = { view, focus: undefined, tree: undefined };
    // Only the top root keeps a tree, so a lower root keeps no views of an old layout.
    this.#root.tree = undefined;
    this.#roots.push(layer);
    this.#host.requestFrame();
    return mount;
  }

  /** Make an overlay with `create` above the root and the other overlays. A modal ends the mouse capture. */
  overlay(owner: string, create: ViewFactory, options: OverlayOptions = {}): Mount {
    const { modal = true, place } = options;
    if (place !== undefined && typeof place !== "function") throw new TypeError("place is a function of the size");
    let layer: Overlay | undefined;
    const mount = createMount(() => {
      const at = layer === undefined ? -1 : this.#overlays.indexOf(layer);
      if (at >= 0) this.#overlays.splice(at, 1);
      this.#host.requestFrame();
    });
    const view = startView(owner, create, mount, this.#host.report);
    if (view === undefined) return mount;
    layer = { view, mount, modal: modal !== false, place, focus: undefined, tree: undefined };
    if (layer.modal) this.cancelCapture();
    this.#overlays.push(layer);
    this.#host.requestFrame();
    return mount;
  }

  /** Place the views of each layer at the size of the screen. Input and drawing need it first. */
  layout(): void {
    const size = this.#host.size();
    const screen = { column: 0, row: 0, width: size.width, height: size.height };
    this.#root.tree = this.#place(this.#root.view, undefined, screen, screen, undefined, new Set());
    for (const layer of this.#overlays) {
      const rect = layer.place === undefined ? screen : this.#placeOverlay(layer, size, screen);
      layer.tree = this.#place(layer.view, undefined, rect, rect, undefined, new Set());
    }
    const hosted: PlacedView[] = [];
    const collect = (target: Target, layer: object): void => {
      if (isHosted(target.view)) hosted.push({ view: target.view, pane: target.pane, layer });
      for (const child of target.children) collect(child, layer);
    };
    if (this.#root.tree !== undefined) collect(this.#root.tree, ROOTS);
    for (const layer of this.#overlays) if (layer.tree !== undefined) collect(layer.tree, layer);
    this.#host.placed(hosted);
    // A captured view that left the tree gets its `cancel` now: no release can reach it.
    if (this.#capture !== undefined && this.#find(this.#capture.view) === undefined) this.cancelCapture();
    this.#syncFocus();
  }

  /** Draw the root tree, then each overlay over a blank rect, then the cursor of the focused view. */
  draw(): void {
    const focused = new Set(this.#path.map((target) => target.view));
    // The frame starts blank in the terminal colors, so only a theme with a background needs this fill.
    const blank = this.#host.screen.resolve(undefined);
    if (blank.bg !== undefined) {
      const size = this.#host.size();
      this.#host.screen.fill(0, 0, size.width, size.height, blank);
    }
    if (this.#root.tree !== undefined) this.#drawTarget(this.#root.tree, focused);
    for (const layer of this.#overlays) {
      if (layer.tree === undefined) continue;
      const { rect } = layer.tree;
      this.#host.screen.fill(rect.column, rect.row, rect.width, rect.height, blank);
      this.#drawTarget(layer.tree, focused);
    }
    this.#host.cursor(this.#cursor());
  }

  /** Give `event` to the `beforeKeymap` handlers of the focused text widget. */
  beforeKeymap(event: KeyEvent): boolean {
    const view = this.focused;
    if (view === undefined) return false;
    return supportOf(view)?.key(event, "beforeKeymap") === true;
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
      target.view.mouse?.(local(event, target));
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
    capture.view.mouse?.(delivered);
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
    this.#host.requestFrame();
  }

  /** The deepest view on the focus path of the input layer. */
  get focused(): View | undefined {
    return this.#path.at(-1)?.view;
  }

  /** The context atoms of the keymap: `global`, `root` or `overlay`, then the contexts along the focus path. */
  atoms(): string[] {
    const atoms = ["global", this.#inputLayer() === this.#root ? "root" : "overlay"];
    for (const target of this.#path) {
      const contexts = target.view.contexts;
      if (Array.isArray(contexts)) atoms.push(...contexts.filter((atom) => typeof atom === "string"));
    }
    return atoms;
  }

  #placeOverlay(layer: Overlay, size: Size, screen: Rect): Rect {
    const rect = layer.place?.(size) ?? screen;
    return isRect(rect) ? intersect(screen, rect) : screen;
  }

  /** The target of `view` at `rect`, cut to `clip`, with its placed children. A view placed twice keeps its first place. */
  #place(
    view: View,
    pane: Pane | undefined,
    rect: Rect,
    clip: Rect,
    parent: Target | undefined,
    seen: Set<View>,
  ): Target {
    const target: Target = { view, pane, parent, rect, clip, children: [] };
    seen.add(view);
    if (view.layout === undefined) return target;
    const placements = view.layout({ width: rect.width, height: rect.height });
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
      const leaf = this.#host.paneOf(child as View);
      const childPane = leaf === undefined ? pane : leaf.pane;
      const childClip = intersect(clip, childRect);
      target.children.push(this.#place(child as View, childPane, childRect, childClip, target, seen));
    }
    return target;
  }

  #drawTarget(target: Target, focused: Set<View>, inherited?: CanvasStyle): void {
    const own = target.view.style;
    const base = layered(inherited, own);
    const canvas = createCanvas(this.#host.screen, target.rect, target.clip, base);
    if (own !== undefined) canvas.fill(0, 0, target.rect.width, target.rect.height);
    target.view.draw(canvas, focused.has(target.view));
    for (const child of target.children) this.#drawTarget(child, focused, base);
  }

  /** Give `value` to the handler of each view on the focus path of `layer`, from the deepest view up. */
  #bubble<A>(layer: Layer, handler: (view: View) => ((value: A) => boolean) | undefined, value: A): boolean {
    for (let target = this.#focusTarget(layer); target !== undefined; target = target.parent) {
      const { view } = target;
      if (handler(view)?.call(view, value) === true) return true;
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
        const view = target.view;
        // The view of a pane takes a press, as it takes the focus without `focusable`.
        if (this.#host.paneOf(view) !== undefined || (view.focusable === true && view.focusOnPress !== false)) {
          this.#setFocus(layer, view);
          break;
        }
      }
    }
    for (let target: Target | undefined = hit; target !== undefined; target = target.parent) {
      const current = target;
      const { view } = current;
      if (view.mouse?.(local(event, current)) === true) {
        // A handler that opened a modal gave the input away, so it gets no capture.
        if (event.action === "press" && event.button === "left" && this.#inputLayer() === input) {
          const point = { column: event.column, row: event.row };
          this.#capture = { view, button: event.button, point };
        }
        return true;
      }
    }
    return false;
  }

  #setFocus(layer: Layer, view: View): void {
    if (layer === this.#root) this.#rootFocus = view;
    else layer.focus = view;
    this.#syncFocus();
    this.#host.requestFrame();
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
    return this.#remembered(fallen ?? layer.tree);
  }

  /**
   * The last focused view inside `target` when it is still in the subtree. Else the `initialFocus` of `target` when it
   * is in the subtree and can take the focus. Else `target`.
   */
  #remembered(target: Target): Target {
    const inner = this.#lastInside.get(target.view);
    const remembered = inner === undefined ? undefined : findIn(target, inner);
    if (remembered !== undefined) return remembered;
    const initial = target.view.initialFocus;
    const found = initial === undefined ? undefined : findIn(target, initial);
    return found !== undefined && this.#focusable(found.view) ? found : target;
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
    const previous = before.at(-1)?.view;
    const change =
      deepest === previous ? undefined : Object.freeze({ previous, current: deepest, pane: path.at(-1)?.pane });
    if (inputChanged || !sameViews(rootPath, rootBefore)) this.#host.focusMoved(rootPath, change);
  }

  /** Tell the view of `target` its focus change. A target of an earlier layout reaches a view that left the tree. */
  #notifyFocus(target: Target, focused: boolean): void {
    target.view.focusChanged?.(focused);
  }

  #focusable(view: View): boolean {
    return view.focusable === true || this.#host.paneOf(view) !== undefined;
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

  #cursor(): Cursor | undefined {
    const target = this.#focusTarget(this.#inputLayer());
    if (target === undefined || target.view.cursor === undefined) return undefined;
    const cursor = target.view.cursor();
    if (cursor === undefined || !Number.isFinite(cursor.column) || !Number.isFinite(cursor.row)) return undefined;
    const screen = {
      column: target.rect.column + Math.floor(cursor.column),
      row: target.rect.row + Math.floor(cursor.row),
      ...(cursor.shape === undefined ? {} : { shape: cursor.shape }),
    };
    return inside(target.clip, screen) ? screen : undefined;
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
