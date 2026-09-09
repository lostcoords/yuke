import { check } from "yuke:test";
import { root, status, copy } from "yuke:core";
import { term } from "yuke:term";
import { plugins } from "yuke:ext";
import { notice, noticePlugin } from "yuke:notice";
import { tuiPlugin } from "yuke:tui";
plugins.use(tuiPlugin);
term.copy = (x) => x.length;

check("silent-before-load", status.side("left").indexOf("copied") < 0);
plugins.use(noticePlugin);

copy("hello", "reply");
check("reports-a-copy", notice.text.indexOf("copied reply") === 0);
check("draws-on-status", status.side("left").indexOf("copied reply") >= 0);
copy("again", "source");
check("reports-every-copy", notice.text.indexOf("copied source") === 0);

// The next key press clears the message, so it never outstays its keystroke.
root.onEvent({ type: "key", code: "char", char: "a", text: "a", event: "press", mods: 0 });
check("clears-on-key", notice.text === "");

// An unload takes the status segment and both listeners with it.
notice.show("held");
plugins.dispose("notice");
check("unload-drops-segment", status.side("left").indexOf("held") < 0);
copy("world", "reply");
check("unload-stops-listening", notice.text === "held");
root.onEvent({ type: "key", code: "char", char: "b", text: "b", event: "press", mods: 0 });
check("unload-stops-clearing", notice.text === "held");

// A reload starts clean, so it never shows the message the unload left behind.
plugins.use(noticePlugin);
check("reload-starts-clean", notice.text === "" && status.side("left").indexOf("held") < 0);

// A key release must not clear a message a copy raised between press and release.
copy("x", "reply");
root.onEvent({ type: "key", code: "char", char: "c", text: "c", event: "release", mods: 0 });
check("release-keeps-notice", notice.text.indexOf("copied reply") === 0);

// The empty and oversize branches each report their own message.
copy("", "reply");
check("empty-copy", notice.text === "nothing to copy");
term.copy = () => -1;
copy("big", "reply");
check("oversize-copy", notice.text.indexOf("too large to copy") === 0);
term.copy = (x) => x.length;

// Showing and clearing must each ask for a repaint, or the message never reaches the screen.
notice.clear();
root._needsDraw = false;
notice.show("repaint me");
check("show-repaints", root._needsDraw === true);
root._needsDraw = false;
notice.clear();
check("clear-repaints", root._needsDraw === true);

globalThis.checkEngineNotice = () => {
  check("reports-engine-notice", notice.text === "terminal write failed");
};
