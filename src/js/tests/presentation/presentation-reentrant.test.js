import { equal } from "yuke:internal/test";
import { ChatSurface, Session } from "yuke:internal/chat";
import { ChatView } from "yuke:internal/chat-view";
import { Text } from "yuke:internal/ui";
import { row, child, fixed, grow } from "yuke:internal/layout";
import { Context, Scope } from "yuke:internal/ext";
const view = new ChatView(new Session()), bounds = { x: 0, y: 0, w: 30, h: 10 };
const mountScope = new Scope("mount");
new ChatSurface(new Context(mountScope, "mount"), null).presentation(() => {
  mountScope.dispose(); return state => state.defaultLayout;
});
view.layout(bounds);
const mountClosed = view.presentation === null && view.presentationViews.length === 0;
mountScope.dispose();
const layoutScope = new Scope("layout");
new ChatSurface(new Context(layoutScope, "layout"), null).presentation(() => state => {
  layoutScope.dispose();
  return row([child(null, grow(), { layout: state.defaultLayout }), child(new Text({ text: "stale" }), fixed(10))]);
});
view.layout(bounds);
equal(mountClosed && view.presentation === null && view.presentationViews.length === 0 && view.composer.rect.w === 30 ? "ok" : "stale presentation", "ok");
