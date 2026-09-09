import { check } from "yuke:test";
import { status } from "yuke:core";
import { plugins } from "yuke:ext";
import { tui } from "yuke:tui";
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

// The status registry orders each side, rejects a bad segment, and disposes with the scope.
const offA = status.add({ side: "left", order: 10, render: () => "a" });
status.add({ side: "left", order: 1, render: () => "b" });
status.add({ side: "right", order: 0, render: () => "r" });
status.add({ side: "left", order: 5, render: () => null });
check("status-order", status.side("left") === "b · a");
check("status-side", status.side("right") === "r");
check("status-bad-side", throws(() => status.add({ side: "up", render: () => "x" })));
check("status-bad-order", throws(() => status.add({ order: Infinity, render: () => "x" })));
check("status-no-render", throws(() => status.add({ side: "left" })));
offA();
check("status-dispose", status.side("left") === "b");
{
  const stop = plugins.use({ name: "seg", apply: (c) => { tui.bindTo(c).status({ side: "right", order: 9, render: () => "p" }); } });
  check("status-plugin", status.side("right") === "r · p");
  stop();
  check("status-unload", status.side("right") === "r");
}
