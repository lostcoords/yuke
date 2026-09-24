// yuke:tui — the terminal capability. A block that declares `tui` registers its view effects here.
import { command, keymap, route, slot, context, status, style, root } from "yuke:core";
import { events } from "yuke:kernel";
import { ChatView } from "yuke:chat-view";
import { scopeOf } from "yuke:ext";
import { registerLabels } from "yuke:transcript";

/** @import { PresentationContext, PresentationProvider } from "yuke:chat-view" */
/** @import { LayoutNode } from "./types/layout.js" */
/** @import { Context, Scope } from "yuke:ext" */
/** @typedef {() => void} Disposer */
/** @typedef {Parameters<typeof command.add>[0]} CommandPredicate */
/** @typedef {Parameters<typeof command.add>[1]} CommandMap */
/** @typedef {NonNullable<Parameters<typeof command.add>[2]>} CommandMetaMap */
/** @typedef {Parameters<typeof keymap.add>[0]} KeyBindings */
/** @typedef {Parameters<typeof route.add>[0]} RouteWhere */
/** @typedef {Parameters<typeof root.addTickable>[0]} Tickable */
/** @typedef {Parameters<typeof root.pushOverlay>[0]} Overlay */
/** @typedef {Parameters<typeof status.add>[0]} StatusSegment */
/** @typedef {Parameters<typeof style.add>[0]} StyleGroups */
/** @typedef {Parameters<typeof context.add>[0]} ContextFlags */

// The surface that owns an overlay. A later claim replaces the earlier one.
/** @typedef {{ surface: object, onClose: (() => void) | undefined }} OverlayClaim */
/** @type {WeakMap<object, OverlayClaim>} */
const OVERLAY_OWNER = new WeakMap();

// Build the terminal surface for one block, so the disposal of that block reverts every registration.
/** @param {Context} ctx */
function bindTo(ctx) {
  // A bare name becomes "<id>:<name>". A name that already holds a ":" stays as the author wrote it.
  /** @param {string} name @returns {string} */
  const qualify = (name) => (name.indexOf(":") >= 0 ? name : ctx.id + ":" + name);
  let ownsOverlays = false;

  const surface = {
    // `meta` names the user actions in `map`. A command without metadata stays a keymap target and never lists.
    /** @param {CommandPredicate} predicate @param {CommandMap} map @param {CommandMetaMap} [meta] @returns {Disposer} */
    command(predicate, map, meta) {
      const scoped = Object.create(null);
      for (const name in map) scoped[qualify(name)] = map[name];
      const scopedMeta = Object.create(null);
      for (const name in meta || {}) scopedMeta[qualify(name)] = /** @type {CommandMetaMap} */ (meta)[name];

      return ctx.effect(() => command.add(predicate, scoped, scopedMeta));
    },

    /** @param {KeyBindings} bindings @param {string} [at] @param {Parameters<typeof keymap.add>[2]} [opts] @returns {Disposer} */
    keymap(bindings, at, opts) {
      return ctx.effect(() => keymap.add(bindings, at, opts));
    },

    /** @param {RouteWhere} where @param {string} [at] @returns {Disposer} */
    route(where, at) {
      return ctx.effect(() => route.add(where, at));
    },

    /** @param {Function} target @param {string} name @param {(obj: any, arg?: any) => unknown} fn @returns {Disposer} */
    slot(target, name, fn) {
      return ctx.effect(() => slot.add(target, name, fn));
    },

    // The nearest class wins, then the newest registration; each mounted pane owns one child scope.
    /** @param {(view: ChatView, scope: Scope) => (context: PresentationContext) => LayoutNode | null} create @returns {Disposer} */
    presentation(create) {
      if (typeof create !== "function") throw new TypeError("presentation needs a factory");
      return ctx.effect(() => {
        /** @type {Set<ChatView>} */
        const mounted = new Set();
        /** @type {PresentationProvider} */
        const provider = {
          mount(view) {
            const scope = scopeOf(ctx).child("presentation");
            try {
              const layout = create(view, scope);
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
        const offSlot = slot.add(ChatView, "presentation", () => provider);
        const offClose = events.on("pane.closed", view => {
          if (view instanceof ChatView) view.clearPresentation(provider);
        });
        root.invalidate();
        return () => {
          offSlot();
          offClose();
          for (const view of mounted) view.clearPresentation(provider);
          root.invalidate();
        };
      });
    },

    // Name tool calls and message sources in the transcript; the newest registration wins.
    /** @param {Parameters<typeof registerLabels>[0]} entries @returns {Disposer} */
    labels(entries) {
      return ctx.effect(() => registerLabels(entries));
    },

    /** @param {ContextFlags} flags @returns {Disposer} */
    context(flags) {
      return ctx.effect(() => context.add(flags));
    },

    /** @param {StatusSegment} seg @returns {Disposer} */
    status(seg) {
      return ctx.effect(() => status.add(seg));
    },

    /** @param {StyleGroups} groups @returns {Disposer} */
    style(groups) {
      return ctx.effect(() => style.add(groups));
    },

    // Show a layer that this block owns; an unload takes it off the stack. `onClose` runs once, at the disposer or at the unload.
    /** @param {Overlay} layer @param {() => void} [onClose] @returns {Disposer} */
    overlay(layer, onClose) {
      // A dead scope reverts nothing, so a late layer never shows and never outlives its block.
      if (!ctx.alive) {
        root.popOverlay(layer);
        onClose?.();
        return () => {};
      }
      if (root.overlays.indexOf(layer) < 0) root.pushOverlay(layer);

      // The map holds the claim, so a frozen layer and a proxy layer both stay untouched.
      /** @type {OverlayClaim} */
      const claim = { surface, onClose };
      OVERLAY_OWNER.set(layer, claim);
      // One effect per surface keeps the disposal order that the block's own effects observe.
      if (!ownsOverlays) {
        ownsOverlays = true;
        ctx.effect(() => () => {
          for (const l of root.overlays.slice()) {
            const owner = OVERLAY_OWNER.get(l);
            if (owner?.surface !== surface) continue;
            OVERLAY_OWNER.delete(l);
            root.popOverlay(l);
            owner.onClose?.();
          }
        });
      }

      // Drop this one claim, so the block can release a layer before it unloads.
      return () => {
        if (OVERLAY_OWNER.get(layer) !== claim) return;
        OVERLAY_OWNER.delete(layer);
        root.popOverlay(layer);
        onClose?.();
      };
    },

    // Ask for a frame after state changes outside an input event, such as an async load.
    invalidate: () => root.invalidate(),

    // A tickable joins the frame loop and receives `onStart`, `onStop`, `needsTick`, and `tick`.
    /** @param {Tickable} tickable @returns {Disposer} */
    tickable(tickable) {
      return ctx.effect(() => {
        root.addTickable(tickable);
        return () => root.removeTickable(tickable);
      });
    },
  };

  return surface;
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
