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

/**
 * A saved pane: a typed view, a split, or `null`.
 * `null` is an empty pane, a failed view, or a view without a snapshot.
 */
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
