// The bundled plugin `files`: the `@` completion of the paths in the folder of a session, from Git or from a walk.

import type { ChatService, CompletionList, CompletionProvider } from "yuke:chat";
import { mkdir, writeTextFile } from "yuke:fs";
import { apply } from "yuke:internal/bundled/files";
import type { PluginContext } from "yuke:plugins";
import { Command } from "yuke:process";
import { equal, folder, test } from "yuke:test";

/** The provider that the plugin adds. */
function provider(): CompletionProvider {
  let added: CompletionProvider | undefined;
  const chat = {
    addCompletionProvider: (value: CompletionProvider) => {
      added = value;
      return () => {};
    },
  } as unknown as ChatService;
  const stop = new AbortController();
  apply({ get: () => chat, signal: stop.signal } as unknown as PluginContext);
  if (added === undefined) throw new Error("no provider");
  return added;
}

/** The labels and inserts of the list of `text` with the caret at its end in `cwd`. */
async function complete(files: CompletionProvider, text: string, cwd: string) {
  const list = (await files.complete({ text, caret: text.length, cwd, signal: new AbortController().signal })) as
    | CompletionList
    | undefined;
  return list === undefined
    ? undefined
    : { from: list.from, items: list.items.map((item) => [item.label, item.insert]) };
}

async function write(root: string, paths: readonly string[]): Promise<void> {
  for (const path of paths) {
    await mkdir(`${root}/${path.slice(0, path.lastIndexOf("/") + 1)}`, { recursive: true });
    await writeTextFile(`${root}/${path}`, "");
  }
}

test("a walk lists the folders and files shallow first, and leaves out hidden entries, node_modules, and target", async () => {
  const root = folder();
  await write(root, ["b.md", "src/main.rs", ".env", ".git-like/x", "node_modules/m/i.js", "target/debug/y", "a b.txt"]);
  const files = provider();

  equal(await complete(files, "read @", root), {
    from: 5,
    items: [
      ["@b.md", "@b.md "],
      ["@src/", "@src/"],
      ["@src/main.rs", "@src/main.rs "],
    ],
  });
});

test("a word without @ at its start is not a mention, and a query keeps the matching paths", async () => {
  const root = folder();
  await write(root, ["docs/guide.md", "src/main.rs"]);
  const files = provider();

  equal(
    [await complete(files, "mail@exa", root), await complete(files, "see @mai", root)],
    [undefined, { from: 4, items: [["@src/main.rs", "@src/main.rs "]] }],
  );
});

test("a Git folder lists the tracked and the untracked files that no ignore rule takes", async () => {
  const root = folder();
  await write(root, [".gitignore", "kept.md", "build/out.js", "notes/todo.md"]);
  await writeTextFile(`${root}/.gitignore`, "build/\n");
  const init = await new Command("git", { args: ["init", "--quiet"], cwd: root }).output();
  const files = provider();

  equal(
    [init.success, await complete(files, "@", root)],
    [
      true,
      {
        from: 0,
        items: [
          ["@notes/", "@notes/"],
          ["@kept.md", "@kept.md "],
          ["@.gitignore", "@.gitignore "],
          ["@notes/todo.md", "@notes/todo.md "],
        ],
      },
    ],
  );
});
