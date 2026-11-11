// The public module `yuke:fs`: reads, writes, directories, facts, failures, and stops.

import * as fs from "yuke:fs";
import { folder } from "yuke:internal/test";
import { Command } from "yuke:process";
import { assert, equal, rejects, test } from "yuke:test";

/** Run `program` with `args` in `cwd`, check that it succeeds, and give its stdout. */
async function run(cwd: string, program: string, ...args: string[]): Promise<Uint8Array> {
  const output = await new Command(program, { args, cwd }).output();
  assert(output.success, `${program} ${args.join(" ")}: ${text(output.stderr)}`);
  return output.stdout;
}

/** Whether `path` in `cwd` names a file or a folder, after symbolic links, as `test -e` tells it. */
async function exists(cwd: string, path: string): Promise<boolean> {
  const output = await new Command("test", { args: ["-e", path], cwd }).output();
  assert(output.code <= 1, `test -e ${path} failed with ${output.code}`);
  return output.success;
}

/** `bytes` as UTF-8 text. */
function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

/** Await the `FileSystemError` that `promise` rejects with. */
async function failure(promise: Promise<unknown>): Promise<fs.FileSystemError> {
  const error = await rejects(promise);
  assert(error instanceof fs.FileSystemError, `expected a FileSystemError, got ${String(error)}`);
  return error;
}

// Paths and options.

test("text and bytes round trip through a relative path and a base folder", async () => {
  const base = folder();
  await fs.writeTextFile("note.txt", "héllo \uD800", { cwd: base });
  equal(await fs.readTextFile(`${base}/note.txt`), "héllo �");
  await fs.writeFile("data.bin", new Uint8Array([0, 1, 2, 3, 4]).subarray(1, 4), { cwd: base });
  equal(await fs.readFile("data.bin", { cwd: base }), new Uint8Array([1, 2, 3]));
  equal(await fs.readFile("data.bin", { cwd: base, position: 1, length: 1 }), new Uint8Array([2]));
  equal(await fs.readFile("data.bin", { cwd: base, position: 9 }), new Uint8Array([]));
  equal(await run(base, "cat", "data.bin"), new Uint8Array([1, 2, 3]));
});

test("a bad path or option throws a type error", async () => {
  const base = folder();
  const errors = await Promise.all([
    rejects(fs.readTextFile("relative.txt")),
    rejects(fs.readTextFile("relative.txt", { cwd: "not/absolute" })),
    rejects(fs.readTextFile("")),
    rejects(fs.readTextFile("a\0b", { cwd: base })),
    rejects(fs.readFile("x", { cwd: base, position: -1 })),
    // @ts-expect-error: the data is an array, not bytes.
    rejects(fs.writeFile("x", [1], { cwd: base })),
  ]);
  equal(
    errors.map((error) => (error instanceof Error ? error.name : error)),
    Array(6).fill("TypeError"),
  );
});

// Failures.

test("a failure is a file system error with a code and the absolute path", async () => {
  const base = folder();
  await fs.writeFile("binary.dat", new Uint8Array([0x61, 0xff]), { cwd: base });
  const errors = [
    await failure(fs.readTextFile("gone.txt", { cwd: base })),
    await failure(fs.readTextFile("binary.dat", { cwd: base, fatal: true })),
    await failure(fs.readFile(base)),
    await failure(fs.writeTextFile("missing/folder/x.txt", "x", { cwd: base })),
    await failure(fs.rename("gone.txt", "other.txt", { cwd: base })),
  ];
  equal(
    errors.map((error) => ({ name: error.name, code: error.code, path: error.path, destination: error.destination })),
    [
      { name: "FileSystemError", code: "ENOENT", path: `${base}/gone.txt`, destination: undefined },
      { name: "FileSystemError", code: "EILSEQ", path: `${base}/binary.dat`, destination: undefined },
      { name: "FileSystemError", code: "EISDIR", path: base, destination: undefined },
      { name: "FileSystemError", code: "ENOENT", path: `${base}/missing/folder/x.txt`, destination: undefined },
      { name: "FileSystemError", code: "ENOENT", path: `${base}/gone.txt`, destination: `${base}/other.txt` },
    ],
  );
});

test("a failure message names the problem and the path", async () => {
  const base = folder();
  const error = await failure(fs.readTextFile("gone.txt", { cwd: base }));
  equal(error.message, `the path does not exist: ${base}/gone.txt`);
});

test("a symbolic link loop rejects with eloop", async () => {
  const base = folder();
  await run(base, "ln", "-s", "second", "first");
  await run(base, "ln", "-s", "first", "second");
  equal((await failure(fs.stat("first", { cwd: base }))).code, "ELOOP");
});

test("a read or a write of a fifo rejects at once and does not wait for its other end", async () => {
  const base = folder();
  await run(base, "mkfifo", "pipe");
  equal(
    [
      (await failure(fs.readFile("pipe", { cwd: base }))).code,
      (await failure(fs.writeTextFile("pipe", "x", { cwd: base }))).code,
      (await failure(fs.writeTextFile("pipe", "x", { cwd: base, atomic: true }))).code,
    ],
    ["EINVAL", "EINVAL", "EINVAL"],
  );
  await run(base, "test", "-p", "pipe");
});

// Reads and writes.

test("a text read replaces bytes that are not utf8 and a fatal read rejects", async () => {
  const base = folder();
  await fs.writeFile("mixed.txt", new Uint8Array([0x61, 0xff, 0x62, 0xe2, 0x82]), { cwd: base });
  equal(await fs.readTextFile("mixed.txt", { cwd: base }), "a�b�");
  equal((await failure(fs.readTextFile("mixed.txt", { cwd: base, fatal: true }))).code, "EILSEQ");
});

test("a write appends creates only a new file or needs an existing one", async () => {
  const base = folder();
  await fs.writeTextFile("log.txt", "one\n", { cwd: base });
  await run(base, "ln", "-s", `${base}/nowhere`, "dangling");
  await fs.writeTextFile("log.txt", "two\n", { cwd: base, append: true });
  await fs.writeTextFile("started.txt", "x", { cwd: base, append: true });
  equal((await failure(fs.writeTextFile("log.txt", "x", { cwd: base, createNew: true }))).code, "EEXIST");
  equal((await failure(fs.writeTextFile("dangling", "x", { cwd: base, createNew: true }))).code, "EEXIST");
  await fs.writeTextFile("fresh.txt", "new", { cwd: base, createNew: true, create: false });
  equal((await failure(fs.writeTextFile("missing.txt", "x", { cwd: base, create: false }))).code, "ENOENT");
  await fs.writeTextFile("log.txt", "tail", { cwd: base, append: true, create: false });
  equal(
    [
      text(await run(base, "cat", "log.txt")),
      text(await run(base, "cat", "started.txt")),
      text(await run(base, "cat", "fresh.txt")),
    ],
    ["one\ntwo\ntail", "x", "new"],
  );
  equal([await exists(base, "missing.txt"), await exists(base, "nowhere")], [false, false]);
});

test("an atomic write with append create new or without create is a misuse", async () => {
  const base = folder();
  const options = { cwd: base, atomic: true };
  equal(
    [
      await rejects(fs.writeTextFile("x.txt", "x", { ...options, append: true })),
      await rejects(fs.writeTextFile("x.txt", "x", { ...options, createNew: true })),
      await rejects(fs.writeTextFile("x.txt", "x", { ...options, create: false })),
    ],
    [
      new TypeError("the options atomic and append exclude each other"),
      new TypeError("the options atomic and createNew exclude each other"),
      new TypeError("an atomic write needs create"),
    ],
  );
  equal(await exists(base, "x.txt"), false);
});

test("an atomic write into a missing folder fails and leaves no temporary file", async () => {
  const base = folder();
  equal((await failure(fs.writeTextFile("gone/x.txt", "x", { cwd: base, atomic: true }))).code, "ENOENT");
  equal(await exists(base, "gone"), false);
});

test("a time before the epoch is a date and not null", async () => {
  const base = folder();
  await run(base, "touch", "-t", "196001010000", "old.txt");
  const info = await fs.stat("old.txt", { cwd: base });
  assert(info.mtime !== null && info.mtime.getUTCFullYear() < 1970, `the time is ${String(info.mtime)}`);
});

// Directories.

test("read dir gives the entries by name and stat and lstat tell a link from its target", async () => {
  const base = folder();
  await fs.mkdir("dir/sub", { cwd: base, recursive: true });
  await fs.writeTextFile("dir/b.txt", "four", { cwd: base });
  await fs.writeTextFile("dir/a.txt", "", { cwd: base });
  await run(base, "ln", "-s", "b.txt", "dir/link");
  equal(await fs.readDir("dir", { cwd: base }), [
    { name: "a.txt", isFile: true, isDirectory: false, isSymlink: false },
    { name: "b.txt", isFile: true, isDirectory: false, isSymlink: false },
    { name: "link", isFile: false, isDirectory: false, isSymlink: true },
    { name: "sub", isFile: false, isDirectory: true, isSymlink: false },
  ]);
  const target = await fs.stat("dir/link", { cwd: base });
  const link = await fs.lstat("dir/link", { cwd: base });
  equal(
    { isFile: target.isFile, isSymlink: target.isSymlink, size: target.size },
    { isFile: true, isSymlink: false, size: 4 },
  );
  equal({ isFile: link.isFile, isSymlink: link.isSymlink }, { isFile: false, isSymlink: true });
  assert(target.mtime instanceof Date && Math.abs(target.mtime.getTime() - Date.now()) < 60_000);
  equal(await exists(base, "dir/link"), true);
});

test("remove needs recursive for a full folder and force accepts a missing path", async () => {
  const base = folder();
  await fs.mkdir("full/inner", { cwd: base, recursive: true });
  await fs.mkdir("empty", { cwd: base });
  await fs.writeTextFile("file.txt", "x", { cwd: base });
  equal((await failure(fs.remove("full", { cwd: base }))).code, "ENOTEMPTY");
  await fs.remove("full", { cwd: base, recursive: true });
  await fs.remove("empty", { cwd: base });
  await fs.remove("file.txt", { cwd: base });
  equal((await failure(fs.remove("gone", { cwd: base }))).code, "ENOENT");
  await fs.remove("gone", { cwd: base, force: true });
  equal([await exists(base, "full"), await exists(base, "file.txt")], [false, false]);
});

test("rename moves a file and replaces one at the destination", async () => {
  const base = folder();
  await fs.writeTextFile("a.txt", "new", { cwd: base });
  await fs.writeTextFile("b.txt", "old", { cwd: base });
  await fs.rename("a.txt", "b.txt", { cwd: base });
  equal(await fs.readTextFile("b.txt", { cwd: base }), "new");
  equal(await exists(base, "a.txt"), false);
});

// Stops.

test("an aborted signal rejects with its reason and changes nothing", async () => {
  const base = folder();
  // A plain object reason must not become a `FileSystemError`.
  const reason = { why: "stop" };
  const error = await rejects(fs.writeTextFile("x.txt", "x", { cwd: base, signal: AbortSignal.abort(reason) }));
  assert(error === reason, `the reason is ${String(error)}`);
  equal(await exists(base, "x.txt"), false);
});

// The abort comes in the turn of the call, so the first check stops the read. A Rust test stops a write between chunks.
test("an abort of a read rejects with the reason and a fake abort event does not", async () => {
  const base = folder();
  await fs.writeTextFile("small.txt", "bytes", { cwd: base });
  const controller = new AbortController();
  const reading = fs.readFile("small.txt", { cwd: base, signal: controller.signal });
  controller.abort("stop");
  equal(await rejects(reading), "stop");
  const faked = new AbortController();
  const whole = fs.readTextFile("small.txt", { cwd: base, signal: faked.signal });
  faked.signal.dispatchEvent(new Event("abort"));
  equal(await whole, "bytes");
});
