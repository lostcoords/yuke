// The public module `yuke:fs`: reads, writes, directories, facts, failures, and stops.

import * as fs from "yuke:fs";
import { folder } from "yuke:internal/test";
import { Command } from "yuke:process";
import { assert, equal, rejects, test } from "yuke:test";

/** Make the empty folder `name` in the scratch folder of the file, and give its absolute path. */
async function place(name: string): Promise<string> {
  const path = `${folder()}/${name}`;
  await fs.mkdir(path);
  return path;
}

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

/** The names of the entries of `cwd`, also the hidden ones, as `ls` tells them. */
async function names(cwd: string): Promise<string[]> {
  return text(await run(cwd, "ls", "-A"))
    .split("\n")
    .filter((name) => name !== "");
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
  const base = await place("round_trip");
  await fs.writeTextFile("note.txt", "héllo \uD800", { baseDir: base });
  equal(await fs.readTextFile(`${base}/note.txt`), "héllo �");
  await fs.writeFile("data.bin", new Uint8Array([0, 1, 2, 3, 4]).subarray(1, 4), { baseDir: base });
  equal(await fs.readFile("data.bin", { baseDir: base }), new Uint8Array([1, 2, 3]));
  equal(await fs.readFile("data.bin", { baseDir: base, position: 1, length: 1 }), new Uint8Array([2]));
  equal(await fs.readFile("data.bin", { baseDir: base, position: 9 }), new Uint8Array([]));
  equal(await run(base, "cat", "data.bin"), new Uint8Array([1, 2, 3]));
});

test("a bad path or option throws a type error", async () => {
  const base = await place("bad_path");
  const errors = await Promise.all([
    rejects(fs.readTextFile("relative.txt")),
    rejects(fs.readTextFile("relative.txt", { baseDir: "not/absolute" })),
    rejects(fs.readTextFile("")),
    rejects(fs.readTextFile("a\0b", { baseDir: base })),
    rejects(fs.readFile("x", { baseDir: base, position: -1 })),
    rejects(fs.readFile("x", { baseDir: base, length: 1.5 })),
    // @ts-expect-error: the data is an array, not bytes.
    rejects(fs.writeFile("x", [1], { baseDir: base })),
    rejects(fs.mkdir("x", { baseDir: base, mode: 0o1_0000 })),
    // @ts-expect-error: the signal is a plain object.
    rejects(fs.readTextFile("x", { baseDir: base, signal: {} })),
  ]);
  equal(
    errors.map((error) => (error instanceof Error ? error.name : error)),
    Array(9).fill("TypeError"),
  );
});

// A typo or a coerced value would change the operation without a word, so each one throws before the operation.
test("an unknown option or an option of another type throws and changes nothing", async () => {
  const base = await place("unknown_option");
  await fs.mkdir("keep", { baseDir: base });
  await fs.writeTextFile("keep/note.txt", "kept", { baseDir: base });
  const errors = await Promise.all([
    // @ts-expect-error: recursive is a string.
    rejects(fs.remove("keep", { baseDir: base, recursive: "false" })),
    // @ts-expect-error: force is a number.
    rejects(fs.remove("keep/note.txt", { baseDir: base, force: 1 })),
    // @ts-expect-error: atmoic is a typo.
    rejects(fs.writeTextFile("new.txt", "x", { baseDir: base, atmoic: true })),
    // @ts-expect-error: atomic is a string.
    rejects(fs.writeTextFile("new.txt", "x", { baseDir: base, atomic: "yes" })),
    // @ts-expect-error: recursive is a number.
    rejects(fs.mkdir("new", { baseDir: base, recursive: 0 })),
    // @ts-expect-error: the options are null.
    rejects(fs.readTextFile("keep/note.txt", null)),
    // @ts-expect-error: baseDir is a number.
    rejects(fs.readTextFile("keep/note.txt", { baseDir: 1 })),
    // @ts-expect-error: a text read has no length.
    rejects(fs.readTextFile("keep/note.txt", { baseDir: base, signal: undefined, length: 1 })),
    // @ts-expect-error: readDir is not recursive.
    rejects(fs.readDir("keep", { baseDir: base, recursive: true })),
  ]);
  equal(errors, [
    new TypeError("the option recursive is not a boolean"),
    new TypeError("the option force is not a boolean"),
    new TypeError("the options has the unknown field 'atmoic'"),
    new TypeError("the option atomic is not a boolean"),
    new TypeError("the option recursive is not a boolean"),
    new TypeError("the options is not an object"),
    new TypeError("the option baseDir is not a string"),
    new TypeError("the options has the unknown field 'length'"),
    new TypeError("the options has the unknown field 'recursive'"),
  ]);
  equal(await fs.readTextFile(`${base}/keep/note.txt`, { baseDir: undefined, signal: undefined }), "kept");
  equal(
    [await exists(base, "keep/note.txt"), await exists(base, "new.txt"), await exists(base, "new")],
    [true, false, false],
  );
});

// Failures.

test("a failure is a file system error with a code and the absolute path", async () => {
  const base = await place("failure");
  await fs.writeFile("binary.dat", new Uint8Array([0x61, 0xff]), { baseDir: base });
  const errors = [
    await failure(fs.readTextFile("gone.txt", { baseDir: base })),
    await failure(fs.readTextFile("binary.dat", { baseDir: base, fatal: true })),
    await failure(fs.readFile(base)),
    await failure(fs.writeTextFile("missing/folder/x.txt", "x", { baseDir: base })),
    await failure(fs.rename("gone.txt", "other.txt", { baseDir: base })),
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
  const base = await place("failure_message");
  const error = await failure(fs.readTextFile("gone.txt", { baseDir: base }));
  equal(error.message, `the path does not exist: ${base}/gone.txt`);
});

test("a symbolic link loop rejects with eloop", async () => {
  const base = await place("link_loop");
  await run(base, "ln", "-s", "second", "first");
  await run(base, "ln", "-s", "first", "second");
  equal((await failure(fs.stat("first", { baseDir: base }))).code, "ELOOP");
});

test("a read or a write of a fifo rejects at once and does not wait for its other end", async () => {
  const base = await place("fifo");
  await run(base, "mkfifo", "pipe");
  equal(
    [
      (await failure(fs.readFile("pipe", { baseDir: base }))).code,
      (await failure(fs.writeTextFile("pipe", "x", { baseDir: base }))).code,
      (await failure(fs.writeTextFile("pipe", "x", { baseDir: base, atomic: true }))).code,
    ],
    ["EINVAL", "EINVAL", "EINVAL"],
  );
  await run(base, "test", "-p", "pipe");
});

// Reads and writes.

test("a text read replaces bytes that are not utf8 and a fatal read rejects", async () => {
  const base = await place("not_utf8");
  await fs.writeFile("mixed.txt", new Uint8Array([0x61, 0xff, 0x62, 0xe2, 0x82]), { baseDir: base });
  equal(await fs.readTextFile("mixed.txt", { baseDir: base }), "a�b�");
  equal((await failure(fs.readTextFile("mixed.txt", { baseDir: base, fatal: true }))).code, "EILSEQ");
});

test("a write appends creates only a new file or needs an existing one", async () => {
  const base = await place("write_modes");
  await fs.writeTextFile("log.txt", "one\n", { baseDir: base });
  await run(base, "ln", "-s", `${base}/nowhere`, "dangling");
  await fs.writeTextFile("log.txt", "two\n", { baseDir: base, append: true });
  await fs.writeTextFile("started.txt", "x", { baseDir: base, append: true });
  equal((await failure(fs.writeTextFile("log.txt", "x", { baseDir: base, createNew: true }))).code, "EEXIST");
  equal((await failure(fs.writeTextFile("dangling", "x", { baseDir: base, createNew: true }))).code, "EEXIST");
  await fs.writeTextFile("fresh.txt", "new", { baseDir: base, createNew: true, create: false });
  equal((await failure(fs.writeTextFile("missing.txt", "x", { baseDir: base, create: false }))).code, "ENOENT");
  await fs.writeTextFile("log.txt", "tail", { baseDir: base, append: true, create: false });
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
  const base = await place("atomic_misuse");
  const options = { baseDir: base, atomic: true };
  equal(
    [
      await rejects(fs.writeTextFile("x.txt", "x", { ...options, append: true })),
      await rejects(fs.writeTextFile("x.txt", "x", { ...options, createNew: true })),
      await rejects(fs.writeTextFile("x.txt", "x", { ...options, create: false })),
      // @ts-expect-error: create is a number.
      await rejects(fs.writeTextFile("x.txt", "x", { baseDir: base, create: 1 })),
    ],
    [
      new TypeError("the options atomic and append exclude each other"),
      new TypeError("the options atomic and createNew exclude each other"),
      new TypeError("an atomic write needs create"),
      new TypeError("the option create is not a boolean"),
    ],
  );
  equal(await exists(base, "x.txt"), false);
});

test("an atomic write into a missing folder fails and leaves no temporary file", async () => {
  const base = await place("atomic_missing_folder");
  equal((await failure(fs.writeTextFile("gone/x.txt", "x", { baseDir: base, atomic: true }))).code, "ENOENT");
  equal(await exists(base, "gone"), false);
});

test("a failed atomic write removes its temporary file", async () => {
  const base = await place("atomic_failed");
  await fs.mkdir("taken/inner", { baseDir: base, recursive: true });
  await failure(fs.writeTextFile("taken", "x", { baseDir: base, atomic: true }));
  equal(await names(base), ["taken"]);
});

test("a time before the epoch is a date and not null", async () => {
  const base = await place("before_epoch");
  await run(base, "touch", "-t", "196001010000", "old.txt");
  const info = await fs.stat("old.txt", { baseDir: base });
  assert(info.mtime !== null && info.mtime.getUTCFullYear() < 1970, `the time is ${String(info.mtime)}`);
});

// Directories.

test("read dir gives the entries by name and stat and lstat tell a link from its target", async () => {
  const base = await place("read_dir");
  await fs.mkdir("dir/sub", { baseDir: base, recursive: true });
  await fs.writeTextFile("dir/b.txt", "four", { baseDir: base });
  await fs.writeTextFile("dir/a.txt", "", { baseDir: base });
  await run(base, "ln", "-s", "b.txt", "dir/link");
  equal(await fs.readDir("dir", { baseDir: base }), [
    { name: "a.txt", isFile: true, isDirectory: false, isSymlink: false },
    { name: "b.txt", isFile: true, isDirectory: false, isSymlink: false },
    { name: "link", isFile: false, isDirectory: false, isSymlink: true },
    { name: "sub", isFile: false, isDirectory: true, isSymlink: false },
  ]);
  const target = await fs.stat("dir/link", { baseDir: base });
  const link = await fs.lstat("dir/link", { baseDir: base });
  equal(
    { isFile: target.isFile, isSymlink: target.isSymlink, size: target.size },
    { isFile: true, isSymlink: false, size: 4 },
  );
  equal({ isFile: link.isFile, isSymlink: link.isSymlink }, { isFile: false, isSymlink: true });
  assert(target.mtime instanceof Date && Math.abs(target.mtime.getTime() - Date.now()) < 60_000);
  equal(await exists(base, "dir/link"), true);
});

test("remove needs recursive for a full folder and force accepts a missing path", async () => {
  const base = await place("remove");
  await fs.mkdir("full/inner", { baseDir: base, recursive: true });
  await fs.mkdir("empty", { baseDir: base });
  await fs.writeTextFile("file.txt", "x", { baseDir: base });
  equal((await failure(fs.remove("full", { baseDir: base }))).code, "ENOTEMPTY");
  await fs.remove("full", { baseDir: base, recursive: true });
  await fs.remove("empty", { baseDir: base });
  await fs.remove("file.txt", { baseDir: base });
  equal((await failure(fs.remove("gone", { baseDir: base }))).code, "ENOENT");
  await fs.remove("gone", { baseDir: base, force: true });
  equal([await exists(base, "full"), await exists(base, "file.txt")], [false, false]);
});

test("rename moves a file and replaces one at the destination", async () => {
  const base = await place("rename");
  await fs.writeTextFile("a.txt", "new", { baseDir: base });
  await fs.writeTextFile("b.txt", "old", { baseDir: base });
  await fs.rename("a.txt", "b.txt", { baseDir: base });
  equal(await fs.readTextFile("b.txt", { baseDir: base }), "new");
  equal(await exists(base, "a.txt"), false);
});

// Stops.

test("an aborted signal rejects with its reason and changes nothing", async () => {
  const base = await place("aborted");
  // A plain object reason must not become a `FileSystemError`.
  const reason = { why: "stop" };
  const error = await rejects(fs.writeTextFile("x.txt", "x", { baseDir: base, signal: AbortSignal.abort(reason) }));
  assert(error === reason, `the reason is ${String(error)}`);
  equal(await exists(base, "x.txt"), false);
});

test("an abort during a large read stops it with the reason and a fake abort event does not", async () => {
  const base = await place("abort_read");
  await fs.writeFile("big.bin", new Uint8Array(64 << 20), { baseDir: base });
  const controller = new AbortController();
  const reading = fs.readFile("big.bin", { baseDir: base, signal: controller.signal });
  controller.abort("stop");
  equal(await rejects(reading), "stop");
  const faked = new AbortController();
  const whole = fs.readFile("big.bin", { baseDir: base, signal: faked.signal });
  faked.signal.dispatchEvent(new Event("abort"));
  equal((await whole).length, 64 << 20);
});

test("an abort during a large atomic write leaves the old file and no temporary file", async () => {
  const base = await place("abort_atomic_write");
  await fs.writeTextFile("big.bin", "old", { baseDir: base });
  const controller = new AbortController();
  const writing = fs.writeFile("big.bin", new Uint8Array(64 << 20), {
    baseDir: base,
    atomic: true,
    signal: controller.signal,
  });
  controller.abort("stop");
  equal(await rejects(writing), "stop");
  equal(text(await run(base, "cat", "big.bin")), "old");
  equal(await names(base), ["big.bin"]);
});
