// The built-in tools `read`, `write`, and `edit` of yuke, called in the folder of the test.

import { readFile, readTextFile, writeFile, writeTextFile } from "yuke:fs";
import { createHost, equal, folder, type TestSession, test } from "yuke:test";

/** The text of a call of `name` with `args` that succeeds. */
async function text(session: TestSession, name: string, args: unknown): Promise<string> {
  const result = await session.call(name, args);
  equal(result.isError, false);
  return result.text;
}

/** The text of a call of `name` with `args` that fails. */
async function error(session: TestSession, name: string, args: unknown): Promise<string> {
  const result = await session.call(name, args);
  equal(result.isError, true);
  return result.text;
}

/** An open session of a host without plugins: the built-in tools only. */
async function opened() {
  const host = await createHost({ plugins: [] });
  return { host, session: await host.openSession() };
}

test("read numbers the lines and names the next offset", async () => {
  await writeTextFile(`${folder()}/notes.txt`, "alpha\nbeta\ngamma\ndelta\n");
  const { host, session } = await opened();
  await using _host = host;

  equal(
    await text(session, "read", { path: "notes.txt", offset: 2, limit: 2 }),
    "2: beta\n3: gamma\n[read more: offset 4.]",
  );
});

test("a null optional field counts as absent", async () => {
  await writeTextFile(`${folder()}/notes.txt`, "one\ntwo\n");
  const { host, session } = await opened();
  await using _host = host;

  equal(await text(session, "read", { path: "notes.txt", offset: null, limit: null }), "1: one\n2: two");
});

test("read stops at the output cap after a whole line", async () => {
  const lines = Array.from({ length: 2000 }, (_item, index) => `line ${String(index + 1).padStart(40)}\n`).join("");
  await writeTextFile(`${folder()}/long.txt`, lines);
  const { host, session } = await opened();
  await using _host = host;

  const read = await text(session, "read", { path: "long.txt" });

  const cut = read.lastIndexOf("\n");
  const [shown, marker] = [read.slice(0, cut), read.slice(cut + 1)];
  const last = Number(shown.split("\n").at(-1)?.split(":")[0]);
  const size = new TextEncoder().encode(shown).length;
  equal([marker, size < 50 * 1024, size + 60 > 50 * 1024], [`[read more: offset ${last + 1}.]`, true, true]);
});

test("a line longer than the cap is cut", async () => {
  await writeTextFile(`${folder()}/one.txt`, `${"é".repeat(40 * 1024)}\nshort\n`);
  const { host, session } = await opened();
  await using _host = host;

  const read = await text(session, "read", { path: "one.txt" });

  const parts = read.split("\n");
  const shown = parts.slice(0, -2).join("\n");
  const size = new TextEncoder().encode(shown).length;
  equal(parts.slice(-2), ["[read cut: line 1 at 50 KiB.]", "[read more: offset 2.]"]);
  equal([shown.startsWith("1: éé"), size <= 50 * 1024 && size > 50 * 1024 - 4], [true, true]);
});

// The texts are the texts of `yuke:fs`, and a FIFO fails before an open that would wait for its other end.
test("read of a missing file, a binary file, a FIFO, or a folder fails with the path", async () => {
  await writeFile(`${folder()}/binary.dat`, new Uint8Array([0x61, 0xff, 0xfe, 0x0a]));
  const { host, session } = await opened();
  await using _host = host;
  equal((await session.call("exec", { command: "mkfifo pipe" })).isError, false);

  const errors = [];
  for (const path of ["gone.txt", "binary.dat", "pipe", "."]) errors.push(await error(session, "read", { path }));

  equal(errors, [
    `the path does not exist: ${folder()}/gone.txt`,
    `the bytes are not valid UTF-8: ${folder()}/binary.dat`,
    `the path names a special file: ${folder()}/pipe`,
    `the path is a directory: ${folder()}/.`,
  ]);
});

test("an image read answers media", async () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52]);
  await writeFile(`${folder()}/dot.png`, png);
  const { host, session } = await opened();
  await using _host = host;

  const result = await session.call("read", { path: "dot.png" });

  equal(
    [result.text, result.media.map((item) => [item.mimeType, [...item.bytes]])],
    ["The tool read the image.", [["image/png", [...png]]]],
  );
});

test("write makes the missing folders in the workspace", async () => {
  const { host, session } = await opened();
  await using _host = host;

  equal(await text(session, "write", { path: "src/deep/new.txt", content: "héllo" }), "The tool wrote 6 bytes.");
  equal(await readTextFile(`${folder()}/src/deep/new.txt`), "héllo");
});

test("edit replaces one exact match", async () => {
  await writeTextFile(`${folder()}/main.rs`, "fn main() {\n    old();\n}\n");
  const { host, session } = await opened();
  await using _host = host;

  const edited = await text(session, "edit", { path: "main.rs", old_string: "old();", new_string: "new($&);" });

  equal(
    [edited, await readTextFile(`${folder()}/main.rs`)],
    ["The tool replaced 1 match.", "fn main() {\n    new($&);\n}\n"],
  );
});

test("edit of two matches needs replace_all", async () => {
  await writeTextFile(`${folder()}/list.txt`, "a, b, a\n");
  const { host, session } = await opened();
  await using _host = host;

  const refused = await error(session, "edit", { path: "list.txt", old_string: "a", new_string: "c" });
  const unchanged = await readTextFile(`${folder()}/list.txt`);
  const edited = await text(session, "edit", { path: "list.txt", old_string: "a", new_string: "c", replace_all: true });

  equal(refused, "old_string matches more than one place. Add context to old_string, or set replace_all to true.");
  equal(
    [unchanged, edited, await readTextFile(`${folder()}/list.txt`)],
    ["a, b, a\n", "The tool replaced 2 matches.", "c, b, c\n"],
  );
});

test("edit without a match fails", async () => {
  await writeTextFile(`${folder()}/list.txt`, "a, b\n");
  const { host, session } = await opened();
  await using _host = host;

  equal(
    await error(session, "edit", { path: "list.txt", old_string: "z", new_string: "c" }),
    "The file has no match for old_string. Read the file and copy the exact text.",
  );
});

test("edit of a missing file names its path", async () => {
  const { host, session } = await opened();
  await using _host = host;

  equal(
    await error(session, "edit", { path: "gone.txt", old_string: "a", new_string: "b" }),
    `the path does not exist: ${folder()}/gone.txt`,
  );
});

test("edit of a file that is not UTF-8 fails and keeps its bytes", async () => {
  const latin = new Uint8Array([0x63, 0x61, 0x66, 0xe9, 0x20, 0x6f, 0x6c, 0x64]);
  await writeFile(`${folder()}/latin1.txt`, latin);
  const { host, session } = await opened();
  await using _host = host;

  const refused = await error(session, "edit", { path: "latin1.txt", old_string: "old", new_string: "new" });

  equal(refused, `the bytes are not valid UTF-8: ${folder()}/latin1.txt`);
  equal([...(await readFile(`${folder()}/latin1.txt`))], [...latin]);
});
