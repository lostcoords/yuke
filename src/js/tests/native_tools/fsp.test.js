import { fs } from "yuke:internal/native/fs";
const fail = [];
const check = (name, cond) => { if (!cond) fail.push(name); };
globalThis.done = 0;
(async () => {
  // A relative path anchors at the directory the host runs in.
  check("read", await fs.readFile("hello.txt") === "one\ntwo\n");
  // The host builds the range object directly, so its keys, nulls, and numbers must match the public shape exactly.
  check("range-end", JSON.stringify(await fs.readRange("hello.txt", { start: 1, end: 1 })) === '{"text":"one\\n","next":null,"longLines":0}');
  check("range-limit", JSON.stringify(await fs.readRange("hello.txt", { start: 2 })) === '{"text":"two\\n","next":null,"longLines":0}');
  check("write-count", await fs.writeFile("made.txt", "abc") === 3);
  check("read-back", await fs.readFile("made.txt") === "abc");
  const info = await fs.stat("made.txt");
  check("stat-file", info !== null && info.isDirectory === false);
  check("stat-missing", await fs.stat("nope.txt") === null);
  // A failure rejects with an Error rather than answering a sentinel.
  let message = "";
  try { await fs.readFile("nope.txt"); } catch (e) { message = e.message; }
  check("read-missing-rejects", message === "the path does not exist");
  // removeFile takes one regular file, and a missing path resolves false.
  check("remove", await fs.removeFile("made.txt") === true);
  check("remove-gone", await fs.stat("made.txt") === null);
  check("remove-missing", await fs.removeFile("made.txt") === false);
  let directory = "";
  try { await fs.removeFile("."); } catch (e) { directory = e.message; }
  check("remove-directory-rejects", directory === "the path names a directory or a special file");
  let coerced = false;
  const path = { toString() { coerced = true; return "hello.txt"; } };
  const wrongPath = async (call) => { try { await call(); return ""; } catch (e) { return e.message; } };
  check("stat-non-string-rejects", await wrongPath(() => fs.stat(path)) === "the path must be a string with no NUL byte");
  check("list-non-string-rejects", await wrongPath(() => fs.list(path)) === "the path must be a string with no NUL byte");
  check("write-non-string-rejects", await wrongPath(() => fs.writeFile(path, "x")) === "the path must be a string with no NUL byte" && !coerced);
  // A NUL byte would cut the path short in the OS, so every path argument rejects it.
  const nulMessage = async (call) => { try { await call(); return ""; } catch (e) { return e.message; } };
  check("nul-remove-rejects", await nulMessage(() => fs.removeFile("hello.txt\0.bak")) === "the path must be a string with no NUL byte");
  check("nul-read-rejects", await nulMessage(() => fs.readFile("hello.txt\0.bak")) === "the path must be a string with no NUL byte");
  check("nul-range-rejects", await nulMessage(() => fs.readRange("hello.txt\0.bak", { start: 1, end: 1 })) === "the path must be a string with no NUL byte");
  check("nul-root-rejects", await nulMessage(() => fs.readFile("hello.txt", { workspaceRoot: "/tmp\0" })) === "the workspace root must be an absolute path");
  globalThis.done = fail.length ? 2 : 1;
})();
