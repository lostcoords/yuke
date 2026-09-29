import { check } from "yuke:internal/test";
import { events, fault, notifications, notify } from "yuke:internal/kernel";

// A throwing listener must not vanish, and the other listeners still run.
const seen = [];
events.on("notify.posted", (n) => seen.push(n.source + ":" + n.message));
events.on("myplugin:go", () => { throw new Error("boom"); });
events.on("myplugin:go", () => seen.push("second"));
events.emit("myplugin:go");
check("reported", seen.indexOf("myplugin:go:boom") >= 0);
check("others-ran", seen.indexOf("second") >= 0);
check("stack-kept", notifications[notifications.length - 1].stack !== "");

// A repeat of the newest entry increases its count. The same message with another stack is a new entry.
notify("info", "same", "t");
notify("info", "same", "t");
check("repeat-counts", notifications[notifications.length - 1].count === 2);
notify("info", "same", "t", "other stack");
check("stack-separates", notifications[notifications.length - 1].count === 1);

// The history keeps only the newest 100 entries.
for (let i = 0; i < 150; i++) notify("info", "n" + i, "t");
check("history-cap", notifications.length === 100 && notifications[0].message === "n50" && notifications[99].message === "n149");

// The cap never splits a surrogate pair.
notify("info", "a".repeat(1022) + "\u{1F600}b", "t");
check("cap-keeps-pairs", notifications[notifications.length - 1].message === "a".repeat(1022) + "…");

// A thrown value that fails every read still reports.
fault(Object.create(null), "t");
check("fault-total", notifications[notifications.length - 1].message === "a thrown value that has no readable text");

// A `notify.posted` listener that calls `notify` must not recurse. The inner notification still enters the history.
const echo = events.on("notify.posted", () => notify("info", "echo", "echo"));
notify("info", "outer", "t");
echo();
const inner = notifications[notifications.length - 1];
check("listener-notify-kept", inner.message === "echo" && inner.count === 1);

// A `notify.posted` listener that throws must not re-enter the bus. Its fault still enters the history.
events.on("notify.posted", () => { throw new Error("second fault"); });
events.emit("myplugin:go");
const last = notifications[notifications.length - 1];
// A re-entry would record the same fault at every level of the recursion, and the repeats would increase the count.
check("listener-fault-kept", last.source === "notify.posted" && last.message === "second fault" && last.count === 1);
