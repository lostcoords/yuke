import { check } from "yuke:internal/test";
import { root, command } from "yuke:internal/core";
import { plugins, services } from "yuke:internal/ext";
import { client } from "yuke:internal/client";
import { tuiPlugin } from "yuke:internal/tui";
import { Composer } from "yuke:internal/ui";
import { Transcript, registerRender } from "yuke:internal/transcript";
import { defaultRender } from "yuke:internal/transcript-view";
import { Session, currentPane, currentSession, showSession, sessionsPlugin } from "yuke:internal/session";
import { composerVim } from "yuke:internal/composer-vim";
import { shell } from "yuke:internal/shell";

registerRender(defaultRender);

const cancels = [];
client.sessionOpen = () => true;
client.sessionClose = () => {};
client.sessionActivity = () => null;
client.sessionOutline = () => ({ messages: [], active: null });
client.sessionCancelRun = (id) => { cancels.push(id); return Promise.resolve(); };

// A user chat plugin replaces the bundled one: its pane holds the parts and is no ChatView.
class Plain {
  /** @param {Session} session */
  constructor(session) {
    this.name = "plain";
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.session = session;
    this.transcript = new Transcript({});
    this.composer = new Composer({});
    session.join(this);
  }
  layout() {}
  draw() {}
}
plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use({ name: "plain-chat", apply: (ctx) => { ctx.provide("chat", { bindTo: () => ({ create: (session = new Session()) => new Plain(session) }) }); } });
plugins.use(shell);
plugins.use(composerVim);

const pane = /** @type {Plain} */ (root.active);
check("shell-shows-the-user-pane", pane instanceof Plain && currentPane() === pane && currentSession() === pane.session);

// The features read parts, not the bundled chat: the session commands reach its session and composer-vim its composer.
showSession(pane, "s1");
command.perform("session:interrupt");
check("session-command-reaches-pane", cancels.join(",") === "s1");
const vim = /** @type {{ mode: (c: Composer) => string | null }} */ (services.get("composer-vim"));
check("composer-vim-reaches-pane", vim.mode(pane.composer) === "normal");
