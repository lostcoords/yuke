import { check } from "yuke:internal/test";
import { command, root, copy } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";
import { plugins } from "yuke:internal/ext";
import { notifications, notify } from "yuke:internal/kernel";
import { toastsPlugin } from "yuke:internal/toasts";
import { tuiPlugin } from "yuke:internal/tui";
plugins.use(tuiPlugin);
term.copy = (x) => x.length;

// The test runs the info timers by hand, so it never waits for the real delay.
const timers = [];
globalThis.setTimeout = (fn) => timers.push(fn);
globalThis.clearTimeout = () => {};
const toasts = () => root.overlays.filter((o) => o.name === "toast");
const newest = () => notifications[notifications.length - 1];

// Faults from before the TUI started show on load, the newest four of them. An old info entry stays in the history only.
for (let i = 1; i <= 5; i++) notify("error", "early fault " + i, "index.js");
notify("info", "early info", "x");
plugins.use(toastsPlugin);
check("early-errors-show", toasts().length === 4 && timers.length === 0);
check("newest-early-errors", toasts().map((t) => t.content.text).join(",") === "early fault 2,early fault 3,early fault 4,early fault 5");
command.perform("notify:dismiss");

// An info toast arms a timer and leaves when the timer runs. An error toast stays.
notify("info", "copied", "clipboard");
check("info-shows", toasts().length === 1 && timers.length === 1);
timers.pop()();
check("info-leaves", toasts().length === 0);

// A repeat keeps its toast and shows the new count.
notify("error", "first fault", "t");
notify("warn", "disk changed", "session");
notify("warn", "disk changed", "session");
check("repeat-keeps-one", toasts().length === 2 && newest().count === 2);

// A click on a toast dismisses it. A click elsewhere passes through.
root.flush();
const [first] = toasts();
root.onEvent({ type: "mouse", col: 0, row: 0, button: "left", event: "press", mods: 0, count: 1 });
check("miss-passes", toasts().length === 2);
root.onEvent({ type: "mouse", col: first.rect.x + 1, row: first.rect.y + 1, button: "left", event: "press", mods: 0, count: 1 });
check("click-dismisses", toasts().length === 1 && toasts()[0] !== first);

// A full stack drops the oldest info toast first, so an error stays.
notify("error", "kept", "t");
for (let i = 0; i < 5; i++) notify("info", "n" + i, "t");
check("errors-survive-a-full-stack", toasts().length === 4 && toasts().filter((t) => t.opts.borderGroup === "NotifyError").length === 1);

// ctrl+l dismisses every toast.
root.onEvent({ type: "key", code: "char", char: "l", text: "l", event: "press", mods: 4 });
check("ctrl-l-dismisses", toasts().length === 0);

// The clipboard reports each result.
copy("hello", "reply");
check("copy-reports", newest().message === "copied reply · 5 bytes");
copy("", "reply");
check("empty-copy", newest().message === "nothing to copy");
term.copy = () => -1;
copy("big", "reply");
check("oversize-copy", newest().level === "warn" && newest().message.indexOf("too large to copy") === 0);
term.copy = (x) => x.length;

// The history view shows an entry posted while it is open.
command.perform("notify:history");
root.flush();
const history = root.overlays.find((o) => o.opts?.title === "notifications");
notify("error", "late entry", "t");
root.flush();
const historyRows = [];
history.content.pager.source.rows(80, 0, 400, historyRows, []);
const rowTexts = historyRows.map((r) => r.text).join("\n");
check("history-refreshes", rowTexts.indexOf("late entry") >= 0);
root.popOverlay(history);

// An unload takes every toast with it.
notify("error", "held", "t");
plugins.dispose("toasts");
check("unload-drops-toasts", toasts().length === 0);
// A reload listens again, so the engine notice below enters the history.
plugins.use(toastsPlugin);

globalThis.checkEngineNotice = () => {
  const n = newest();
  check("engine-notice-enters-history", n.level === "error" && n.source === "agents" && n.message === "terminal write failed");
};
