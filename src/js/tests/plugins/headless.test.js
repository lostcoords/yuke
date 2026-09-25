import { equal } from "yuke:internal/test";
import { events, config } from "yuke:internal/kernel";
let fired = 0;
events.on("myplugin:ready", () => { fired += 1; });
events.emit("myplugin:ready");
equal(fired === 1 && config.keymap.chordMs > 0 ? "ok" : "bad", "ok");
