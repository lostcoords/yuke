import { root } from "yuke:core";
const check = (name, ok) => { if (!ok) throw new Error(name); };
let now = 1000;
Date.now = () => now;
let fast = 0, slow = 0;
const a = { needsTick: () => ({ periodMs: 100 }), tick() { fast++; } };
const b = { needsTick: () => ({ periodMs: 500 }), tick() { slow++; } };
root.addTickable(a);
root.addTickable(b);
// The engine frame gap sends a pulse every 33 ms during a stream; each layer still ticks at its own period.
for (let i = 0; i < 45; i++) { root.onEvent({ type: "tick" }); now += 33; }
check("fast-keeps-period", fast === 15);
check("slow-keeps-period", slow === 4);
// A second pulse at the last pulse's time elapses no period, so it ticks nothing and draws nothing.
now -= 33;
root.flush();
root.onEvent({ type: "tick" });
check("nothing-due", fast === 15 && slow === 4 && !root._needsDraw);
// A clock that steps back reads as elapsed.
now -= 100000;
root.onEvent({ type: "tick" });
check("clock-back-ticks", fast === 16 && slow === 5 && root._needsDraw);
root.removeTickable(a);
root.removeTickable(b);
