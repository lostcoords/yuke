import { check } from "yuke:test";
import { term } from "yuke:term";
import { Pager } from "yuke:pager";
const rows = (n) => Array.from({ length: n }, (_, i) => ({ text: "row " + i }));
const frame = (p) => { term.beginFrame(); p.draw({ x: 0, y: 0, w: 10, h: 4 }); term.endFrame(); };

const p = new Pager();
p.setRows(rows(10));
frame(p);
check("starts-at-the-tail", p.stuck === true && p.scroll === 6);

// New rows arrive while the pager sits at the tail, so the view follows them down.
p.setRows(rows(20));
frame(p);
check("stuck-follows-the-tail", p.stuck === true && p.scroll === 16);

// A scroll away from the tail unsticks, and later rows must not move the view.
p.scrollBy(-5);
check("scroll-away-unsticks", p.stuck === false && p.scroll === 11);
p.setRows(rows(30));
frame(p);
check("unstuck-holds-the-offset", p.stuck === false && p.scroll === 11);

// A scroll back to the last row sticks again.
p.scrollBy(100);
check("tail-sticks-again", p.stuck === true && p.scroll === 26);

// `rowCount` walks every message, so one frame must ask for it exactly once.
let asked = 0;
const q = new Pager();
q.setSource({ rowCount: () => { asked++; return 30; }, rows: () => [] });
asked = 0;
frame(q);
check("one-row-count-per-frame", asked === 1);
