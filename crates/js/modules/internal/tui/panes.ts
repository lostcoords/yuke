/**
 * The pane tree of the core: leaves and splits, the active pane, focus by direction and next, and the close of a
 * pane. A new pane of the core shows the default pane of a plugin, or an empty view without one. The close of the last
 * pane gives a new one. The view of the tree places the view of each leaf and draws a one-cell divider between the two
 * parts of each split.
 */
import { createMount, startView } from "yuke:internal/tui/mount";
import type { SavedPane, SavedPanes, ViewType } from "yuke:internal/tui/restore";
import type {
  Canvas,
  DefaultPane,
  Direction,
  FocusDirection,
  Mount,
  Pane,
  PaneReason,
  Placement,
  Rect,
  Size,
  View,
  ViewFactory,
} from "yuke:tui";

interface Leaf {
  readonly kind: "leaf";
  readonly view: View;
  /** The handle of a plugin pane; an empty pane has none. */
  readonly pane: Pane | undefined;
  /** The plugin of the pane, or `core` for an empty pane. */
  readonly owner: string;
}

interface Split {
  readonly kind: "split";
  readonly direction: Direction;
  readonly ratio: number;
  first: Node;
  second: Node;
}

type Node = Leaf | Split;

/** The default pane of a plugin, and the hand-over of each of its panes to that plugin. */
export interface DefaultPaneEntry {
  readonly owner: string;
  readonly create: DefaultPane;
  readonly adopt: (mount: Mount) => void;
}

/** What the tree needs from the core. */
export interface PaneHost {
  /** The default pane, or `undefined` without one. */
  readonly defaultPane: () => DefaultPaneEntry | undefined;
  /** Give the focus to `view`, a view of a leaf. */
  readonly focus: (view: View) => void;
  readonly report: (source: string, text: string) => void;
  readonly requestFrame: () => void;
}

const DIVIDER = Object.freeze({ dim: true });

export class PaneTree {
  readonly #host: PaneHost;
  #root: Node;
  #active: Leaf;
  /** The rects of the leaves and the dividers at the last layout, local to the view of the tree. */
  #leafRects = new Map<Leaf, Rect>();
  /** The leaf of each view at the last layout, so the scene finds a pane at each placed child. */
  #leafViews = new Map<View, Leaf>();
  #dividers: { readonly rect: Rect; readonly direction: Direction }[] = [];
  readonly view: View;

  constructor(host: PaneHost) {
    this.#host = host;
    this.#active = emptyLeaf();
    this.#root = this.#active;
    this.view = Object.freeze({
      layout: (size: Size): readonly Placement[] => this.#layout(size),
      draw: (canvas: Canvas): void => this.#drawDividers(canvas),
    });
  }

  /** The handle of the active pane, or `undefined` while an empty pane is active. */
  get active(): Pane | undefined {
    return this.#active.pane;
  }

  /** The leaf of `view` at the last layout, or `undefined` when no pane shows it. */
  leafOf(view: View): Leaf | undefined {
    return this.#leafViews.get(view);
  }

  /** Split the active pane along `direction`. The new pane comes after it (right or below) and gets the focus. */
  split(owner: string, create: ViewFactory, direction: Direction): Pane {
    if (direction !== "row" && direction !== "column") throw new TypeError("a split direction is row or column");
    const started = this.#startLeaf(owner, create);
    if ("mount" in started) return paneOf(started.mount, emptyView(), () => {});
    this.#insert(started.leaf, direction);
    return started.pane;
  }

  /** Split the active pane along `direction` with a new default pane, which gets the focus. */
  splitDefault(direction: Direction): void {
    this.#insert(this.#defaultLeaf("new"), direction);
  }

  /**
   * Put the default pane of a start in place of the first empty pane in tree order. The new pane gets the focus of the
   * empty pane. Return `false` without a default pane.
   */
  start(): boolean {
    if (this.#host.defaultPane() === undefined) return false;
    const empty = this.#leaves().find((leaf) => leaf.pane === undefined);
    if (empty !== undefined) {
      const leaf = this.#defaultLeaf("start");
      this.#replace(empty, leaf);
      if (this.#active === empty) this.#activate(leaf);
      else this.#host.requestFrame();
    }
    return true;
  }

  /**
   * The saved tree. `save` gives the saved view of a leaf (the plugin of the pane and its view), or `null` for an
   * empty pane or a view without a snapshot.
   */
  snapshot(save: (view: View, owner: string) => SavedPane): SavedPanes {
    const walk = (node: Node): SavedPane =>
      node.kind === "leaf"
        ? save(node.view, node.owner)
        : { split: node.direction, ratio: node.ratio, first: walk(node.first), second: walk(node.second) };
    return { tree: walk(this.#root), focus: Math.max(0, this.#leaves().indexOf(this.#active)) };
  }

  /**
   * Replace the tree with `saved`, and close the panes of the tree before. A `null` leaf gives a new default pane. A
   * type without a factory gives no pane, because its plugin is gone. A factory that fails gives an empty pane and one
   * notice.
   */
  restore(saved: SavedPanes, factoryOf: (type: string) => ViewType | undefined): void {
    const before = this.#leaves();
    const order: (Leaf | undefined)[] = [];
    const build = (pane: SavedPane): Node | undefined => {
      if (pane === null) {
        const leaf = this.#defaultLeaf("new");
        order.push(leaf);
        return leaf;
      }
      if ("split" in pane) {
        const first = build(pane.first);
        const second = build(pane.second);
        if (first === undefined) return second;
        if (second === undefined) return first;
        return { kind: "split", direction: pane.split, ratio: pane.ratio, first, second };
      }
      const leaf = this.#restoreLeaf(pane.state, factoryOf(pane.type));
      order.push(leaf);
      return leaf;
    };
    this.#root = build(saved.tree) ?? this.#defaultLeaf("new");
    for (const leaf of before) leaf.pane?.close();
    this.#activate(order[saved.focus] ?? firstLeaf(this.#root));
  }

  /** Close the active pane: a plugin pane through its mount, an empty pane at once. */
  closeActive(): void {
    const leaf = this.#active;
    if (leaf.pane !== undefined) leaf.pane.close();
    else this.#remove(leaf);
  }

  /**
   * Move the focus to the nearest pane in `direction`: the centers strictly ahead, scored by the distance along plus
   * twice the distance across; the first in tree order wins a tie (Zig `core.js:1377-1398`).
   */
  focus(direction: FocusDirection): boolean {
    const from = this.#leafRects.get(this.#active);
    if (from === undefined) return false;
    const center = (rect: Rect) => ({ x: rect.column + rect.width / 2, y: rect.row + rect.height / 2 });
    const origin = center(from);
    let best: Leaf | undefined;
    let bestScore = Number.POSITIVE_INFINITY;
    for (const leaf of this.#leaves()) {
      const rect = this.#leafRects.get(leaf);
      if (leaf === this.#active || rect === undefined) continue;
      const point = center(rect);
      const dx = point.x - origin.x;
      const dy = point.y - origin.y;
      const along = direction === "left" ? -dx : direction === "right" ? dx : direction === "up" ? -dy : dy;
      const across = direction === "left" || direction === "right" ? dy : dx;
      if (along <= 0) continue;
      const score = along + 2 * Math.abs(across);
      if (score < bestScore) {
        best = leaf;
        bestScore = score;
      }
    }
    if (best === undefined) return false;
    this.#activate(best);
    return true;
  }

  /** Move the focus to the next pane in tree order, after the last to the first. */
  focusNext(): void {
    const leaves = this.#leaves();
    const next = leaves[(leaves.indexOf(this.#active) + 1) % leaves.length];
    if (next !== undefined && next !== this.#active) this.#activate(next);
  }

  /** The focus moved: the leaf on the root focus path becomes the active pane. */
  noteFocus(rootPath: readonly View[]): void {
    const leaf = this.#leaves().find((candidate) => rootPath.includes(candidate.view));
    if (leaf !== undefined) this.#active = leaf;
  }

  /** The view of the active pane, the root focus when the focused view left the tree. */
  activeView(): View {
    return this.#active.view;
  }

  #activate(leaf: Leaf): void {
    this.#active = leaf;
    this.#host.focus(leaf.view);
    this.#host.requestFrame();
  }

  /** Take `leaf` out: its sibling takes the place of their split. The last leaf gives way to a new default pane. */
  #remove(leaf: Leaf): void {
    if (!this.#leaves().includes(leaf)) return;
    let next: Leaf;
    if (this.#root === leaf) {
      next = this.#defaultLeaf("new");
      this.#root = next;
    } else {
      const parent = this.#parentOf(this.#root, leaf);
      if (parent === undefined) return;
      const sibling = parent.first === leaf ? parent.second : parent.first;
      this.#replace(parent, sibling);
      next = firstLeaf(sibling);
    }
    if (this.#active === leaf || !this.#leaves().includes(this.#active)) this.#activate(next);
    else this.#host.requestFrame();
  }

  /** Put `leaf` after the active pane in a new split along `direction`, and give it the focus. */
  #insert(leaf: Leaf, direction: Direction): void {
    const old = this.#active;
    this.#replace(old, { kind: "split", direction, ratio: 0.5, first: old, second: leaf });
    this.#activate(leaf);
  }

  /** Put `replacement` where `node` is in the tree. */
  #replace(node: Node, replacement: Node): void {
    if (this.#root === node) {
      this.#root = replacement;
      return;
    }
    const parent = this.#parentOf(this.#root, node);
    if (parent === undefined) return;
    if (parent.first === node) parent.first = replacement;
    else parent.second = replacement;
  }

  #parentOf(at: Node, node: Node): Split | undefined {
    if (at.kind === "leaf") return undefined;
    if (at.first === node || at.second === node) return at;
    return this.#parentOf(at.first, node) ?? this.#parentOf(at.second, node);
  }

  #leaves(): Leaf[] {
    const leaves: Leaf[] = [];
    const walk = (node: Node): void => {
      if (node.kind === "leaf") leaves.push(node);
      else {
        walk(node.first);
        walk(node.second);
      }
    };
    walk(this.#root);
    return leaves;
  }

  /** The leaf of a saved view, `undefined` without a factory, or an empty leaf when the factory fails. */
  #restoreLeaf(state: unknown, entry: ViewType | undefined): Leaf | undefined {
    if (entry === undefined) return undefined;
    const started = this.#startLeaf(entry.owner, (given) => entry.restore(state, given));
    if ("mount" in started) return emptyLeaf();
    entry.adopt(started.pane);
    return started.leaf;
  }

  /** A new leaf of the default pane, or an empty leaf without one or when it fails. */
  #defaultLeaf(reason: PaneReason): Leaf {
    const entry = this.#host.defaultPane();
    if (entry === undefined) return emptyLeaf();
    const started = this.#startLeaf(entry.owner, (mount) => entry.create(mount, reason));
    if ("mount" in started) return emptyLeaf();
    entry.adopt(started.pane);
    return started.leaf;
  }

  /** Start the view of `create` in a new leaf of `owner`. A view that does not start gives the mount of the attempt. */
  #startLeaf(owner: string, create: ViewFactory): { leaf: Leaf; pane: Pane } | { mount: Mount } {
    let leaf: Leaf | undefined;
    const mount = createMount(() => {
      if (leaf !== undefined) this.#remove(leaf);
    });
    const view = startView(owner, create, mount, this.#host.report);
    if (view === undefined) return { mount };
    const pane = paneOf(mount, view, () => {
      if (leaf !== undefined && this.#leaves().includes(leaf)) this.#activate(leaf);
    });
    leaf = { kind: "leaf", view, pane, owner };
    return { leaf, pane };
  }

  /**
   * Place each leaf. A split gives the first part `ratio` of its cells less the divider. With 3 cells or more, each
   * part gets at least 1; a smaller split can leave a part empty.
   */
  #layout(size: Size): readonly Placement[] {
    this.#leafRects = new Map();
    this.#leafViews = new Map();
    this.#dividers = [];
    const placements: Placement[] = [];
    const walk = (node: Node, rect: Rect): void => {
      if (node.kind === "leaf") {
        this.#leafRects.set(node, rect);
        this.#leafViews.set(node.view, node);
        placements.push({ view: node.view, rect });
        return;
      }
      const row = node.direction === "row";
      const total = (row ? rect.width : rect.height) - 1;
      const first = total <= 1 ? Math.max(0, total) : Math.min(total - 1, Math.max(1, Math.round(total * node.ratio)));
      const second = Math.max(0, total - first);
      if (row) {
        walk(node.first, { ...rect, width: first });
        this.#dividers.push({ rect: { ...rect, column: rect.column + first, width: 1 }, direction: "row" });
        walk(node.second, { ...rect, column: rect.column + first + 1, width: second });
      } else {
        walk(node.first, { ...rect, height: first });
        this.#dividers.push({ rect: { ...rect, row: rect.row + first, height: 1 }, direction: "column" });
        walk(node.second, { ...rect, row: rect.row + first + 1, height: second });
      }
    };
    walk(this.#root, { column: 0, row: 0, width: size.width, height: size.height });
    return placements;
  }

  #drawDividers(canvas: Canvas): void {
    for (const { rect, direction } of this.#dividers) {
      if (direction === "row") {
        for (let row = rect.row; row < rect.row + rect.height; row += 1) canvas.text(rect.column, row, "│", DIVIDER);
      } else {
        canvas.text(rect.column, rect.row, "─".repeat(rect.width), DIVIDER);
      }
    }
  }
}

/** A new view that draws nothing. Each leaf has its own view, because the scene finds a leaf by its view. */
function emptyView(): View {
  return { draw() {} };
}

function emptyLeaf(): Leaf {
  return { kind: "leaf", view: emptyView(), pane: undefined, owner: "core" };
}

function firstLeaf(node: Node): Leaf {
  return node.kind === "leaf" ? node : firstLeaf(node.first);
}

function paneOf(mount: Mount, view: View, focus: () => void): Pane {
  return Object.freeze({ close: mount.close, signal: mount.signal, view, focus });
}
