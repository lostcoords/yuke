// The chat pane plugin: the chat service the shell asks for panes, the chat pane commands, and the vision warning.
import { root } from "yuke:internal/core";
import { modelOf } from "yuke:internal/catalog";
import { ChatView } from "yuke:internal/chat-view";
import { registerRender, toggleExpandAll } from "yuke:internal/transcript";
import { attachClipboard } from "yuke:internal/attach";
import { Session, sessions, currentPane, showSession } from "yuke:internal/session";
import { notify } from "yuke:internal/kernel";

/** @import { Disposer } from "./types/ext.js" */
/** @import { Render } from "./types/transcript.js" */
/** @import { Context } from "yuke:internal/ext" */

// Warn when the images in a view's composer will not reach the model its next input goes to.
/** @param {ChatView} view @param {string} [selector] @returns {void} */
function checkVision(view, selector = view.session.modelSelector()) {
  if (!view.composer.hasImages()) return;
  const model = selector === "" ? null : modelOf(selector);
  // An unknown model, and one whose catalog entry says nothing, never raise a warning.
  if (!model || model.supports_vision !== false) return;
  notify("warn", model.name + " reads no images", "chat");
}

/** The `chat` capability, bound to one plugin block. What the block registers through it ends when the block unloads. */
export class ChatSurface {
  /** @param {Context} ctx */
  constructor(ctx) {
    this._ctx = ctx;
  }

  /**
   * A new chat pane on `session`, or on a new draft when `session` is absent. A pane on an open session shows its history at once.
   * The caller puts the pane in the tree.
   * @param {Session} [session] @returns {ChatView}
   */
  create(session = new Session()) {
    const view = new ChatView(session);
    // A view on an open session shows its history at once, as a view that joins through `showSession` does.
    session.reload([view]);
    return view;
  }

  /**
   * Add a renderer to every transcript for the life of this block. It stacks on the renderers before it: see `Render`.
   * @param {Render} render @returns {Disposer} Removes the renderer before the block unloads.
   */
  render(render) {
    return this._ctx.effect(() => registerRender(render));
  }

  /**
   * Rebuild the rows of part `partId` of message `messageId` in every pane, because its renderer reads state outside the part.
   * @param {number} messageId @param {number} partId @returns {void}
   */
  refresh(messageId, partId) {
    for (const session of sessions) for (const view of session.views) if (view instanceof ChatView) view.transcript.refreshRow(messageId, partId);
    root.invalidate();
  }
}

export const chatPlugin = {
  name: "chat",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // Only the pane whose composer took the attachment warns; another pane's images did not change.
      ctx.on("composer.attached", (composer) => { for (const session of sessions) for (const view of session.views) if (view instanceof ChatView && view.composer === composer) checkVision(view); });
      // The feed reads the patch back later, so a pane on the patched session checks the new model directly.
      ctx.on("model.changed", (ev) => {
        for (const session of sessions) {
          const selector = ev.sessionId !== null && session.sessionId === ev.sessionId ? ev.model.selector : session.modelSelector();
          for (const view of session.views) if (view instanceof ChatView) checkVision(view, selector);
        }
      });

      ctx.tui.command.add("chat:new", {
        desc: "leave the session and start empty",
        slash: true,
        run: () => {
          const pane = currentPane();
          if (!pane) return;
          showSession(pane, new Session());
          root.focusView(pane);
        },
      });
      ctx.tui.command.add("chat:paste-image", { desc: "attach the image on the clipboard", run: () => { const composer = currentPane()?.composer; if (composer) attachClipboard(composer); } });
      ctx.tui.command.add("chat:expand-all", { desc: "open or fold every tool and report", run: toggleExpandAll });
      ctx.tui.keymap.add({ "ctrl+n": "chat:new", "ctrl+v": "chat:paste-image", "ctrl+o": "chat:expand-all" });

      // Provided last, so an unload withdraws the service first and the shell closes the panes while the block still runs.
      ctx.provide("chat", { bindTo: (/** @type {Context} */ c) => new ChatSurface(c) });
    });
  },
};
