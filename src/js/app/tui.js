// yuke:tui — the terminal capability. A block that declares `tui` registers its view effects here.
import { command, keymap, route, slots, context, status, style, root } from "yuke:core";

/** @typedef {import("yuke:ext").Context} Context */
/** @typedef {() => void} Disposer */
/** @typedef {Parameters<typeof command.add>[0]} CommandPredicate */
/** @typedef {Parameters<typeof command.add>[1]} CommandMap */
/** @typedef {Parameters<typeof keymap.add>[0]} KeyBindings */
/** @typedef {Parameters<typeof route.add>[0]} RouteWhere */
/** @typedef {Parameters<typeof root.addTickable>[0]} Tickable */
/** @typedef {Parameters<typeof root.pushOverlay>[0]} Overlay */
/** @typedef {Parameters<typeof status.add>[0]} StatusSegment */
/** @typedef {Parameters<typeof style.add>[0]} StyleGroups */
/** @typedef {Parameters<typeof context.set>[0]} ContextFlags */

// The surface that owns an overlay. A later claim replaces the earlier one.
/** @type {WeakMap<object, object>} */
const OVERLAY_OWNER = new WeakMap();

// Build the terminal surface for one block, so the disposal of that block reverts every registration.
/** @param {Context} ctx @returns {object} */
function bindTo(ctx) {
  // A bare name becomes "<id>:<name>". A name that already holds a ":" stays as the author wrote it.
  /** @param {string} name @returns {string} */
  const qualify = (name) => (name.indexOf(":") >= 0 ? name : ctx.id + ":" + name);
  let ownsOverlays = false;

  const surface = {
    /** @param {CommandPredicate} predicate @param {CommandMap} map @returns {Disposer} */
    command(predicate, map) {
      const scoped = Object.create(null);
      for (const name in map) scoped[qualify(name)] = map[name];

      return ctx.effect(() => command.add(predicate, scoped));
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
      return ctx.effect(() => slots.add(target, name, fn));
    },

    /** @param {ContextFlags} flags @returns {Disposer} */
    context(flags) {
      return ctx.effect(() => context.set(flags));
    },

    /** @param {StatusSegment} seg @returns {Disposer} */
    status(seg) {
      return ctx.effect(() => status.add(seg));
    },

    /** @param {StyleGroups} groups @returns {Disposer} */
    style(groups) {
      return ctx.effect(() => style.add(groups));
    },

    // Claim an overlay by layer so an unload takes it off the stack and a re-push stays owned; pass `ui.pick(...).win`.
    /** @param {Overlay} layer @returns {Overlay} */
    overlay(layer) {
      // A layer off the stack is a caller error, such as a picker handle in place of its window.
      if (root.overlays.indexOf(layer) < 0) throw new Error("overlay: the layer is not on the stack");

      // A dead scope reverts nothing, so the overlay closes now and never outlives its block.
      if (!ctx.scope.alive) {
        while (root.overlays.indexOf(layer) >= 0) root.popOverlay(layer);
        return layer;
      }

      // The map holds the claim, so a frozen layer and a proxy layer both stay untouched.
      OVERLAY_OWNER.set(layer, surface);
      // One effect per surface keeps the disposal order that the block's own effects observe.
      if (!ownsOverlays) {
        ownsOverlays = true;
        ctx.effect(() => () => {
          for (const l of root.overlays.slice()) if (OVERLAY_OWNER.get(l) === surface) root.popOverlay(l);
        });
      }

      return layer;
    },

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
