import { equal } from "yuke:test";
import { ChatView } from "yuke:chat-view";
import { Text } from "yuke:ui";
import { row, child, fixed, grow } from "yuke:layout";
import { Context, Scope } from "yuke:ext";
import { tui } from "yuke:tui";
const view = new ChatView(), bounds = { x: 0, y: 0, w: 30, h: 10 };
const mountScope = new Scope("mount");
tui.bindTo(new Context(mountScope, "mount")).presentation((_chat, owner) => {
  owner.dispose(); return state => state.defaultLayout;
});
view.layout(bounds);
const mountClosed = view.presentation === null && view.presentationViews.length === 0;
mountScope.dispose();
const layoutScope = new Scope("layout");
tui.bindTo(new Context(layoutScope, "layout")).presentation(() => state => {
  layoutScope.dispose();
  return row([child(null, grow(), { layout: state.defaultLayout }), child(new Text({ text: "stale" }), fixed(10))]);
});
view.layout(bounds);
equal(mountClosed && view.presentation === null && view.presentationViews.length === 0 && view.composer.rect.w === 30 ? "ok" : "stale presentation", "ok");
