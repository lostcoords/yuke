// The built-in modules that a module imports by name.

import { mkdir, writeTextFile } from "yuke:fs";
import { assert, equal, folder, rejects, test } from "yuke:test";

test("a user module imports a public built-in module", async () => {
  const plugins = await import("yuke:plugins");
  equal(typeof plugins, "object");
});

test("an unknown built-in name does not load", async () => {
  const name: string = "yuke:nothing";
  const error = await rejects(import(name));
  assert(error instanceof TypeError);
  assert(error.message.includes("no built-in module has the name 'yuke:nothing'"), error.message);
});

// The URL encodes the space of the folder, and the paths keep it.
test("a file module knows its URL, its file, and its folder", async () => {
  const dirname = `${folder()}/a folder`;
  const filename = `${dirname}/meta.ts`;
  await mkdir(dirname);
  await writeTextFile(filename, "export const meta = import.meta;");

  const imported: { meta: ImportMeta } = await import(filename);

  equal(
    [imported.meta.url, imported.meta.filename, imported.meta.dirname],
    [`file://${dirname.replaceAll(" ", "%20")}/meta.ts`, filename, dirname],
  );
  assert(import.meta.filename?.endsWith("/engine/modules.test.ts"), String(import.meta.filename));
});
