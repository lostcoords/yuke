import { fs } from "yuke:fs";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
globalThis.done = 0;
(async () => {
  // A relative path anchors at the directory the host runs in.
  check("read", await fs.readFile("hello.txt") === "one\ntwo\n");
  check("write-count", await fs.writeFile("made.txt", "abc") === 3);
  check("read-back", await fs.readFile("made.txt") === "abc");
  const info = await fs.stat("made.txt");
  check("stat-file", info !== null && info.isDirectory === false);
  check("stat-missing", await fs.stat("nope.txt") === null);
  // A failure rejects with an Error rather than answering a sentinel.
  let message = "";
  try { await fs.readFile("nope.txt"); } catch (e) { message = e.message; }
  check("read-missing-rejects", message === "the path does not exist");
  globalThis.done = fail.length ? 2 : 1;
})();
