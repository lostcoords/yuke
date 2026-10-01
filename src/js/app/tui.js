// The terminal capability. A block that declares `tui` registers its view effects here.
import { command, keymap, route, context, status, style, root, colorDepth } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";

/** @import { Disposer } from "./types/ext.js" */
/** @import { Context } from "yuke:internal/ext" */
/** @import { ViewLike } from "./types/core.js" */
/** @typedef {Parameters<typeof root.addTickable>[0]} Tickable */
/** @typedef {Parameters<typeof root.pushOverlay>[0]} Overlay */

const NOOP = () => {};

// A registry as one block sees it: the shared registry, with registering methods the block owns. Reads and advice reach the shared object.
/** @template {object} R @param {Context} ctx @param {R} registry @param {Array<keyof R & string>} methods @returns {R} */
function owned(ctx, registry, methods) {
  const bound = /** @type {Record<string, unknown>} */ (Object.create(registry));
  for (const method of methods) {
    const register = /** @type {(...args: unknown[]) => Disposer} */ (registry[method]);
    bound[method] = (/** @type {unknown[]} */ ...args) => ctx.effect(() => register.apply(registry, args));
  }
  return /** @type {R} */ (bound);
}

// The methods live on the class, so a block builds one small object and each registry only on first use.
/**
 * The terminal capability as one block sees it: `c.tui` inside `ctx.inject(["tui"], (c) => ...)`.
 * Each `add`, `overlay`, `split`, and `tickable` call belongs to the block. When the block stops, each one goes away.
 * The block stops when its plugin unloads or when the `tui` provider changes.
 */
class Surface {
  /** @param {Context} ctx */
  constructor(ctx) {
    this._ctx = ctx;
    /** The shared root view: the pane tree, the overlays, the focus, and the repaint requests. A change through it does not belong to the block. */
    this.root = root;
  }

  // A registry binds on first use; the bound registry replaces this getter on the instance.
  /** @template T @param {string} name @param {T} value @returns {T} */
  _settle(name, value) {
    Object.defineProperty(this, name, { value });
    return value;
  }

  /**
   * The command registry. `add` registers the command for this block. A name without ":" becomes "<plugin id>:<name>".
   * The other members read the shared registry. After the block stops, `add` throws a TypeError.
   * @returns {typeof command}
   */
  get command() {
    const ctx = this._ctx;
    const bound = /** @type {typeof command} */ (Object.create(command));
    bound.add = (name, spec) => ctx.effect(() => command.add(name.indexOf(":") >= 0 ? name : ctx.id + ":" + name, spec));
    return this._settle("command", bound);
  }
  /**
   * The key binding registry. `add` registers for this block and returns a disposer.
   * The other members read the shared registry. After the block stops, `add` throws a TypeError.
   * @returns {typeof keymap}
   */
  get keymap() { return this._settle("keymap", owned(this._ctx, keymap, ["add"])); }
  /**
   * The key route registry. `add` registers for this block and returns a disposer.
   * The other members read the shared registry. After the block stops, `add` throws a TypeError.
   * @returns {typeof route}
   */
  get route() { return this._settle("route", owned(this._ctx, route, ["add"])); }
  /**
   * The context flag registry. `add` registers for this block and returns a disposer.
   * The other members read the shared registry. After the block stops, `add` throws a TypeError.
   * @returns {typeof context}
   */
  get context() { return this._settle("context", owned(this._ctx, context, ["add"])); }
  /**
   * The status bar segment registry. `add` registers for this block and returns a disposer.
   * The other members read the shared registry. After the block stops, `add` throws a TypeError.
   * @returns {typeof status}
   */
  get status() { return this._settle("status", owned(this._ctx, status, ["add"])); }
  /**
   * The highlight groups. `set`, `setPalette`, and `theme` register for this block and return a disposer.
   * The other members read the shared registry. After the block stops, `set`, `setPalette`, and `theme` throw a TypeError.
   * @returns {typeof style}
   */
  get style() { return this._settle("style", owned(this._ctx, style, ["set", "setPalette", "theme"])); }
  /**
   * The light or dark class of the terminal background. yuke asks the terminal before `index.js` runs, and `background.changed` reports each change.
   * It is "dark" when the terminal does not report its color.
   * @returns {"dark" | "light"}
   */
  get background() { return term.background; }
  /**
   * The color depth that the default palette uses: "truecolor" for 24-bit colors, or "256" for the 256-color palette.
   * The `colors` setting picks it, and "auto" follows `COLORTERM`. `colors.changed` reports each change of the setting.
   * @returns {"truecolor" | "256"}
   */
  get colors() { return colorDepth(); }

  /**
   * Show `layer` above the panes until it closes. The disposer, a pop of the layer, or the block stop closes it.
   * Any close runs `onClose` once. After the block stops, the layer does not show and `onClose` runs at once.
   * @param {Overlay} layer - a view such as the `win` from `ui.pick`. A layer that already shows stays in its place.
   * @param {() => void} [onClose]
   * @returns {Disposer}
   */
  overlay(layer, onClose) {
    // A dead scope reverts nothing, so a late layer never shows and never outlives its block.
    if (!this._ctx.alive) {
      root.popOverlay(layer);
      onClose?.();
      return NOOP;
    }
    if (root.overlays.indexOf(layer) < 0) root.pushOverlay(layer);
    /** @type {Disposer} */
    let off = NOOP;
    // A close drops this block's entry too, so a long-lived block that opens many layers holds none of the closed ones.
    const claim = () => {
      off();
      onClose?.();
    };
    root.closeWith(layer, claim);
    off = this._ctx.effect(() => () => root.popOverlay(layer));
    return off;
  }

  /**
   * Split the focused pane and show `view` in the new pane, which gets the focus. The disposer or the block stop closes that pane.
   * With no focused pane, nothing splits. It throws a TypeError when `view` has no `layout` and `draw` or already shows.
   * @param {"row" | "col"} kind - "row" puts the new pane on the right, and "col" puts it below.
   * @param {ViewLike} view
   * @returns {Disposer}
   */
  split(kind, view) {
    return this._ctx.effect(() => (root.split(kind, view) ? () => root.close(view) : undefined));
  }

  /**
   * Add `tickable` to the frame loop until the disposer runs or the block stops.
   * The loop calls its `onStart`, `onStop`, `needsTick`, and `tick` hooks. Two adds of one object share one entry.
   * @param {Tickable} tickable
   * @returns {Disposer}
   */
  tickable(tickable) {
    return this._ctx.effect(() => {
      root.addTickable(tickable);
      return () => root.removeTickable(tickable);
    });
  }
}

/** The `tui` capability. `ctx.inject(["tui"], ...)` calls `bindTo`, so each block gets its own `Surface`. */
export const tui = { bindTo: (/** @type {Context} */ ctx) => new Surface(ctx) };

/** The plugin that provides the `tui` capability. The shell registers it, and then each block that declares `tui` starts. */
export const tuiPlugin = {
  name: "tui",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.provide("tui", tui);
  },
};
