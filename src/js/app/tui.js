// yuke:tui — the terminal capability. A block that declares `tui` registers its view effects here.
import { command, keymap, route, slot, context, status, style, root, events } from "yuke:core";
import { ChatView } from "yuke:transcript";

/** @typedef {import("yuke:ext").Context} Context */
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
    /** @param {(view: ChatView, scope: import("yuke:ext").Scope) => (context: import("yuke:transcript").PresentationContext) => import("yuke:layout").LayoutNode | null} create @returns {Disposer} */
    presentation(create) {
      if (typeof create !== "function") throw new TypeError("presentation needs a factory");
      return ctx.effect(() => {
        /** @type {Set<ChatView>} */
        const mounted = new Set();
        /** @type {import("yuke:transcript").PresentationProvider} */
        const provider = {
          mount(view) {
            const scope = ctx.scope.child("presentation");
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

    // Claim an overlay by layer so an unload takes it off the stack and a re-push stays owned; pass `ui.pick(...).win`.
    /** @param {Overlay} layer @returns {Disposer} */
    overlay(layer) {
      // A layer off the stack is a caller error, such as a picker handle in place of its window.
      if (root.overlays.indexOf(layer) < 0) throw new TypeError("overlay: the layer is not on the stack");

      // A dead scope reverts nothing, so the overlay closes now and never outlives its block.
      if (!ctx.scope.alive) {
        root.popOverlay(layer);
        return () => {};
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

      // Drop this one claim, so the block can release a layer before it unloads.
      return () => {
        if (OVERLAY_OWNER.get(layer) !== surface) return;
        OVERLAY_OWNER.delete(layer);
        root.popOverlay(layer);
      };
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
