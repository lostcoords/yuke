import { diff } from "yuke:diff";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
globalThis.result = "pending";
(async () => {
  const changed = await diff("a.txt", "one\ntwo\n", "one\ntwo changed\n");
  check("path", changed.path === "a.txt");
  check("one-hunk", changed.hunks.length === 1);
  const lines = changed.hunks[0].lines;
  check("marks", lines[0] === " one" && lines[1] === "-two" && lines[2] === "+two changed");
  check("starts", changed.hunks[0].oldStart === 1 && changed.hunks[0].newStart === 1);
  check("counts", changed.hunks[0].oldLines === 2 && changed.hunks[0].newLines === 2);
  // An equal pair has nothing to show, so the caller drops the view.
  check("equal", (await diff("a.txt", "same\n", "same\n")).hunks.length === 0);
  // A new file states an empty old side with start 0 and count 0.
  const fresh = (await diff("new.txt", "", "fresh\n")).hunks[0];
  check("new-file", fresh.oldStart === 0 && fresh.oldLines === 0 && fresh.lines[0] === "+fresh");
  // A value of another type rejects. A conversion would run a script the argument carries.
  let message = "";
  try { await diff(1, "a\n", "b\n"); } catch (e) { message = e.message; }
  check("number-path-rejects", message === "the path must be a string");
  globalThis.result = fail.length ? fail.join(",") : "ok";
})();
