/**
 * The view types of the plugins and the saved panes of a reload. The old runtime saves the pane tree at
 * `core:reload`; the new one rebuilds it through the factory of each view type after its plugins load.
 */
import type { Direction, Disposer, JsonValue, Mount, RestoreView } from "yuke:tui";

/** A factory of a view type, the plugin that owns it, and the hand-over of a restored pane to that plugin. */
export interface ViewType {
  readonly owner: string;
  readonly restore: RestoreView;
  readonly adopt: (mount: Mount) => void;
}

/** A saved pane: a typed view, a split, or `null`. `null` is an empty pane or a view without a valid snapshot. */
export type SavedPane =
  | null
  | { readonly type: string; readonly state: JsonValue }
  | { readonly split: Direction; readonly ratio: number; readonly first: SavedPane; readonly second: SavedPane };

/** The pane tree and the index of the focused leaf, in tree order. */
export interface SavedPanes {
  readonly tree: SavedPane;
  readonly focus: number;
}

export class ViewTypes {
  readonly #types = new Map<string, ViewType>();

  /** Add the factory of the qualified view type `type`. A type with a factory already throws a `TypeError`. */
  register(type: string, entry: ViewType): Disposer {
    if (this.#types.has(type)) throw new TypeError(`the view type ${type} exists`);
    this.#types.set(type, entry);
    return () => {
      if (this.#types.get(type) === entry) this.#types.delete(type);
    };
  }

  get(type: string): ViewType | undefined {
    return this.#types.get(type);
  }
}

/**
 * The saved panes in the text of a snapshot. A text that is no JSON throws its `SyntaxError`; JSON that is no saved
 * pane tree, or a focus that is no index of a leaf, throws a `TypeError`.
 */
export function readSnapshot(text: string): SavedPanes {
  const value: unknown = JSON.parse(text);
  if (typeof value !== "object" || value === null) throw new TypeError("a snapshot is an object");
  const { tree, focus } = value as { tree?: unknown; focus?: unknown };
  const checked = checkPane(tree);
  if (!Number.isInteger(focus) || (focus as number) < 0 || (focus as number) >= leafCount(checked)) {
    throw new TypeError("the focus of a snapshot is the index of a leaf");
  }
  return { tree: checked, focus: focus as number };
}

function leafCount(pane: SavedPane): number {
  return pane !== null && "split" in pane ? leafCount(pane.first) + leafCount(pane.second) : 1;
}

function checkPane(value: unknown): SavedPane {
  if (value === null) return null;
  if (typeof value !== "object") throw new TypeError("a saved pane is null, a view, or a split");
  const pane = value as Record<string, unknown>;
  if (pane.split === "row" || pane.split === "column") {
    const { ratio } = pane;
    if (typeof ratio !== "number" || !(ratio > 0 && ratio < 1)) throw new TypeError("a split ratio is between 0 and 1");
    return { split: pane.split, ratio, first: checkPane(pane.first), second: checkPane(pane.second) };
  }
  if (typeof pane.type !== "string" || !("state" in pane)) throw new TypeError("a saved view has a type and a state");
  return { type: pane.type, state: pane.state as JsonValue };
}
