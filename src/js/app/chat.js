// The chat pane plugin: the chat service the shell asks for panes, the chat pane commands, and the vision warning.
import { root } from "yuke:internal/core";
import { notice } from "yuke:internal/notice";
import { client } from "yuke:internal/client";
import { modelOf } from "yuke:internal/catalog";
import { ChatView } from "yuke:internal/chat-view";
import { registerLabels } from "yuke:internal/transcript";
import { attachClipboard } from "yuke:internal/attach";
import { Session, sessions, currentPane, showSession } from "yuke:internal/session";

/** @import { Disposer } from "./types/ext.js" */
/** @import { Context } from "yuke:internal/ext" */

// Warn when the images in a view's composer will not reach the model its next input goes to.
/** @param {ChatView} view @param {string} [selector] @returns {void} */
function checkVision(view, selector = view.session.modelSelector()) {
  if (!view.composer.hasImages()) return;
  const model = selector === "" ? null : modelOf(selector);
  // An unknown model, and one whose catalog entry says nothing, never raise a warning.
  if (!model || model.supports_vision !== false) return;
  notice.show(model.name + " reads no images");
  root.invalidate();
}

// One block's view of the chat: the chat features it registers belong to that block.
export class ChatSurface {
  /** @param {Context} ctx */
  constructor(ctx) {
    this._ctx = ctx;
  }

  // A chat view for `session`. The shell asks this for every pane it opens.
  /** @param {Session} [session] @returns {ChatView} */
  create(session = new Session()) {
    const view = new ChatView(session);
    // A view on an open session shows its history at once, as a view that joins through `showSession` does.
    session.reload([view]);
    return view;
  }

  // Name tool calls and message sources in the transcript; the newest registration wins.
  /** @param {Parameters<typeof registerLabels>[0]} entries @returns {Disposer} */
  labels(entries) {
    return this._ctx.effect(() => registerLabels(entries));
  }
}

export const chatPlugin = {
  name: "chat",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The composer owns its own attachments, so each pane answers for the model it sends to.
      ctx.on("composer.attached", () => { for (const session of sessions) for (const view of session.views) if (view instanceof ChatView) checkVision(view); });
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
      ctx.tui.command.add("debug:memory", {
        run: () => {
          const m = client.memoryUsage();
          const mb = (/** @type {number} */ n) => (n / 1048576).toFixed(1) + "MB";
          const k = (/** @type {number} */ n) => Math.round(n / 1000) + "k";
          notice.show("js heap " + mb(m.heap) + " · str " + mb(m.strings) + "/" + k(m.stringCount) +
            " · obj " + mb(m.objects) + "/" + k(m.objectCount) + " · prop " + mb(m.properties) + "/" + k(m.propertyCount) +
            " · shape " + mb(m.shapes) + " · arr " + k(m.arrayCount));
        },
      });
      ctx.tui.keymap.add({ "ctrl+n": "chat:new", "ctrl+v": "chat:paste-image" });

      // Provided last, so an unload withdraws the service first and the shell closes the panes while the block still runs.
      ctx.provide("chat", { bindTo: (/** @type {Context} */ c) => new ChatSurface(c) });
    });
  },
};
