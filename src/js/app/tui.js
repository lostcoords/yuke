// The terminal capability. A block that declares `tui` registers its view effects here.
import { command, keymap, route, context, status, style, root } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { ChatView } from "yuke:internal/chat-view";
import { Context, scopeOf } from "yuke:internal/ext";
import { registerLabels } from "yuke:internal/transcript";

/** @import { PresentationContext, PresentationProvider } from "yuke:internal/chat-view" */
/** @import { LayoutNode } from "./types/layout.js" */
/** @import { Disposer } from "./types/ext.js" */
/** @import { ViewLike } from "./types/core.js" */
/** @typedef {Parameters<typeof root.addTickable>[0]} Tickable */
/** @typedef {Parameters<typeof root.pushOverlay>[0]} Overlay */
/** @typedef {Parameters<typeof command.add>[1]} CommandMap */

const NOOP = () => {};

// A registry as one block sees it: the shared registry, with an `add` the block owns. Reads and advice reach the shared object.
/** @template {{ add(...args: any[]): Disposer }} R @param {Context} ctx @param {R} registry @param {(args: Parameters<R["add"]>) => Parameters<R["add"]>} [prepare] @returns {R} */
function owned(ctx, registry, prepare) {
  const bound = /** @type {R} */ (Object.create(registry));
  bound.add = /** @type {R["add"]} */ ((/** @type {Parameters<R["add"]>} */ ...args) => ctx.effect(() => registry.add(...(prepare ? prepare(args) : args))));
  return bound;
}

// One block's view of the terminal: the shared objects, with registrations the block owns, so its disposal reverts every one.
// The methods live on the class, so a block builds one small object and each registry only on first use.
class Surface {
  /** @param {Context} ctx */
  constructor(ctx) {
    this._ctx = ctx;
    // The shared root: the pane tree, focus, and repaint requests.
    this.root = root;
  }

  // A registry binds on first use; the bound registry replaces this getter on the instance.
  /** @template T @param {string} name @param {T} value @returns {T} */
  _settle(name, value) {
    Object.defineProperty(this, name, { value });
    return value;
  }

  // A bare name becomes "<id>:<name>". A name that already holds a ":" stays as the author wrote it.
  /** @template T @param {Record<string, T> | null | undefined} map @returns {Record<string, T>} */
  _qualify(map) {
    /** @type {Record<string, T>} */
    const scoped = Object.create(null);
    for (const name in map || {}) scoped[name.indexOf(":") >= 0 ? name : this._ctx.id + ":" + name] = /** @type {T} */ ((/** @type {Record<string, T>} */ (map))[name]);
    return scoped;
  }

  // `meta` names the user actions in the map. A command without metadata stays a keymap target and never lists.
  /** @returns {typeof command} */
  get command() {
    return this._settle("command", owned(this._ctx, command, ([predicate, map, meta]) => /** @type {Parameters<typeof command.add>} */ ([predicate, /** @type {CommandMap} */ (this._qualify(map)), meta && this._qualify(meta)])));
  }
  /** @returns {typeof keymap} */
  get keymap() { return this._settle("keymap", owned(this._ctx, keymap)); }
  /** @returns {typeof route} */
  get route() { return this._settle("route", owned(this._ctx, route)); }
  /** @returns {typeof context} */
  get context() { return this._settle("context", owned(this._ctx, context)); }
  /** @returns {typeof status} */
  get status() { return this._settle("status", owned(this._ctx, status)); }
  /** @returns {typeof style} */
  get style() { return this._settle("style", owned(this._ctx, style)); }

  // The newest registration wins; each mounted pane owns one child context.
  /** @param {(view: ChatView, owner: Context) => (context: PresentationContext) => LayoutNode | null} create @returns {Disposer} */
  presentation(create) {
    if (typeof create !== "function") throw new TypeError("presentation needs a factory");
    const ctx = this._ctx;
    return ctx.effect(() => {
      /** @type {Set<ChatView>} */
      const mounted = new Set();
      /** @type {PresentationProvider} */
      const provider = {
        mount(view) {
          const scope = scopeOf(ctx).child("presentation");
          try {
            const layout = create(view, new Context(scope, ctx.id));
            if (typeof layout !== "function") throw new TypeError("presentation factory must return a layout function");
            if (!scope.alive) throw new TypeError("presentation scope closed during mount");
            mounted.add(view);
            return { layout, dispose() { mounted.delete(view); scope.dispose(); } };
          } catch (error) {
            scope.dispose();
            throw error;
          }
        },
      };
      const offAnswer = events.on("chat.presentation", () => provider);
      const offClose = events.on("pane.closed", view => {
        if (view instanceof ChatView) view.clearPresentation(provider);
      });
      root.invalidate();
      return () => {
        offAnswer();
        offClose();
        for (const view of mounted) view.clearPresentation(provider);
        root.invalidate();
      };
    });
  }

  // Name tool calls and message sources in the transcript; the newest registration wins.
  /** @param {Parameters<typeof registerLabels>[0]} entries @returns {Disposer} */
  labels(entries) {
    return this._ctx.effect(() => registerLabels(entries));
  }

  // Show a layer this block owns. Any close runs `onClose` once: a pop by the layer itself, the disposer, or the unload.
  // A later owner of the same layer takes it over, so an earlier owner's unload leaves it on the stack.
  /** @param {Overlay} layer @param {() => void} [onClose] @returns {Disposer} */
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
    off = this._ctx.effect(() => () => root.popOverlay(layer, claim));
    return off;
  }

  // Split the focused pane and show `view` in the new one. The unload closes that pane; no focused pane splits nothing.
  /** @param {"row" | "col"} kind @param {ViewLike} view @returns {Disposer} */
  split(kind, view) {
    return this._ctx.effect(() => (root.split(kind, view) ? () => root.close(view) : undefined));
  }

  // A tickable joins the frame loop and receives `onStart`, `onStop`, `needsTick`, and `tick`.
  /** @param {Tickable} tickable @returns {Disposer} */
  tickable(tickable) {
    return this._ctx.effect(() => {
      root.addTickable(tickable);
      return () => root.removeTickable(tickable);
    });
  }
}

/** @param {Context} ctx @returns {Surface} */
function bindTo(ctx) {
  return new Surface(ctx);
}

// `inject` calls `bindTo`, so each block gets a surface whose effects that block owns.
export const tui = { bindTo };

// The shell registers this plugin, and every block that declares `tui` then activates.
export const tuiPlugin = {
  name: "tui",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.provide("tui", tui);
  },
};
