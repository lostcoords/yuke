import { check } from "yuke:test";
import { ChatView } from "yuke:chat-view";
import { Text } from "yuke:ui";
import { root } from "yuke:core";
import { row, column, child, fixed, fit, grow } from "yuke:layout";
import { Context, Scope } from "yuke:ext";
import { tui } from "yuke:tui";
let sessionId = null;
const view = new ChatView({ sessionId: () => sessionId, textOf: () => "history across sidebar" });
const composer = view.composer, transcript = view.transcript, pager = transcript.pager;
composer.onKey({ type: "paste", text: "draft\nline two\nline three\n" });
const draft = composer.text, caret = composer.input.caret, spans = JSON.stringify(composer.spans);
const scope = new Scope("test");
let mounts = 0, layouts = 0, disposed = 0, contextSession;
tui.bindTo(new Context(scope, "test")).presentation((chat, owner) => {
  mounts++;
  owner.effect(() => () => disposed++);
  const logo = new Text({ text: "welcome 世界" });
  const side = new Text({ text: "session details" });
  return state => {
    layouts++; contextSession = state.sessionId;
    if (!state.empty) return row([child(null, grow(), { layout: state.defaultLayout }), child(side, fixed(18))], { gap: 1 });
    const width = Math.min(40, state.bounds.w);
    return column([child(null, grow()), child(logo, fit(), { intrinsic: logo.measure(width) }),
      child("composer", fit(), { intrinsic: { w: width, h: chat.composer.height(width) } }), child(null, grow())], { align: "center", gap: 1 });
  };
});
root.setActive(view); root.flush();
check("center", composer.rect.x === 10 && composer.rect.y > 2 && composer.rect.y < 15);
check("empty-transcript-hidden", transcript.pager.rect() === null);
const beforeLayout = layouts;
root.invalidatePaint(); root.flush();
check("paint-skips-layout", layouts === beforeLayout && mounts === 1);
sessionId = "session-a";
transcript.setOutline([{ id: 1, type: "user" }], null);
root.invalidate(); root.flush();
check("sidebar", composer.rect.w === 41 && composer.rect.y >= 16);
check("context", contextSession === "session-a");
const mouse = (event, col) => ({ type: "mouse", event, button: "left", col, row: 0, mods: 0, count: 1 });
view.onMouse(mouse("press", 2)); view.onMouse(mouse("drag", 45)); view.onMouse(mouse("release", 45));
check("transcript-capture-crosses-sidebar", transcript.selectedText() === "history across sidebar" && !transcript._dragging);
check("identity", composer === view.composer && transcript === view.transcript && pager === transcript.pager && mounts === 1);
check("draft", composer.text === draft && composer.input.caret === caret && JSON.stringify(composer.spans) === spans);
globalThis.finish = () => {
  scope.dispose(); root.flush();
  check("unload", disposed === 1 && view.presentation === null && view.presentationViews.length === 0 && composer.rect.w === 60);
  root.setActive(null);
};
