import { equal } from "yuke:test";
import { ChatView } from "yuke:chat-view";
import { Text, Window } from "yuke:ui";
import { RootView, events } from "yuke:core";
import { row, child, fixed, grow } from "yuke:layout";
import { Context, Scope } from "yuke:ext";
import { tui } from "yuke:tui";
const view = new ChatView(), scope = new Scope("owners"), otherRoot = new RootView();
const side = new Text({ text: "one owner" }), bounds = { x: 0, y: 0, w: 30, h: 10 };
let errors = 0;
const off = events.on("ext.error", () => errors++);
tui.bindTo(new Context(scope, "owners")).presentation(() => state => row([
  child(null, grow(), { layout: state.defaultLayout }), child(side, fixed(10)),
]));
otherRoot.setActive(side); view.layout(bounds);
const paneRejected = errors === 1 && view.presentation === null;
otherRoot.setActive(null); view.layout(bounds);
let reverseRejected = false, windowRejected = false, composerRejected = false;
try { otherRoot.setActive(side); } catch (error) { reverseRejected = error instanceof TypeError; }
try { new Window({ content: side }); } catch (error) { windowRejected = error instanceof TypeError; }
try { otherRoot.setActive(view.composer); } catch (error) { composerRejected = error instanceof TypeError; }
scope.dispose(); otherRoot.setActive(side);
const released = otherRoot.active === side;
otherRoot.setActive(null); off();
equal(paneRejected && reverseRejected && windowRejected && composerRejected && released ? "ok" : [paneRejected, reverseRejected, windowRejected, composerRejected, released].join(","), "ok");
