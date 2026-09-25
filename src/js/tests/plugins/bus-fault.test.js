import { check } from "yuke:internal/test";
import { events } from "yuke:internal/kernel";

// A throwing listener must not vanish, and the other listeners still run.
const seen = [];
events.on("ext.error", (e, who) => seen.push(String(who) + ":" + e.message));
events.on("myplugin:go", () => { throw new Error("boom"); });
events.on("myplugin:go", () => seen.push("second"));
events.emit("myplugin:go");
check("reported", seen.indexOf("myplugin:go:boom") >= 0);
check("others-ran", seen.indexOf("second") >= 0);

// A throwing `ext.error` listener must not re-enter the bus.
events.on("ext.error", () => { throw new Error("second fault"); });
let looped = false;
try { events.emit("myplugin:go"); looped = true; } catch { looped = true; }
check("no-recursion", looped);
