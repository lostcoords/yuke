// The bundled plugin `files`: the `@` completion of the paths in the folder of a session, from Git or from a walk.

import type { ChatService, CompletionList, CompletionProvider } from "yuke:chat";
import { mkdir, writeTextFile } from "yuke:fs";
import { apply } from "yuke:internal/bundled/files";
import type { PluginContext } from "yuke:plugins";
import { Command, env } from "yuke:process";
import { assertEquals, folder, test } from "yuke:test";

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

/** The labels and inserts of the list of `text` with the caret at its end in `where`. */
async function complete(files: CompletionProvider, text: string, where: string) {
  const list = (await files.complete({
    text,
    caret: text.length,
    folder: where,
    signal: new AbortController().signal,
  })) as CompletionList | undefined;
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
  await write(root, ["b.md", "src/main.rs", ".env", ".git-like/x", "node_modules/m/i.js", "target/debug/y"]);
  const files = provider();

  assertEquals(await complete(files, "read @", root), {
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

  assertEquals(
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

  assertEquals(
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

test("a path with whitespace goes in quotes, a quoted word finds it, and a closed quote ends the mention", async () => {
  const root = folder();
  await write(root, ["my notes.md", "my dir/a.md", 'a "b".md', 'a"b.md']);
  const files = provider();

  assertEquals(
    [
      await complete(files, "@notes", root),
      await complete(files, 'see @"my n', root),
      await complete(files, '@"my di', root),
      await complete(files, '@"my notes.md"', root),
      await complete(files, '@"my notes.md" ', root),
    ],
    [
      { from: 0, items: [['@"my notes.md"', '@"my notes.md" ']] },
      { from: 4, items: [['@"my notes.md"', '@"my notes.md" ']] },
      {
        from: 0,
        items: [
          ['@"my dir/"', '@"my dir/'],
          ['@"my dir/a.md"', '@"my dir/a.md" '],
        ],
      },
      undefined,
      undefined,
    ],
  );
});

test("a path with a quote stays plain, and a path with whitespace and a quote stays out", async () => {
  const root = folder();
  await write(root, ['a "b".md', 'a"b.md']);
  const files = provider();

  assertEquals(await complete(files, "@b.m", root), { from: 0, items: [['@a"b.md', '@a"b.md ']] });
});

test("an @ word that starts as a path lists the entries of the folder that it names", async () => {
  const root = folder();
  await write(root, ["work/a.md", "work/.env", "work/sub/b.md", "work/my dir/c.md", "other/notes.md"]);
  const files = provider();
  const work = `${root}/work`;

  assertEquals(
    [
      await complete(files, "see @./", work),
      await complete(files, "@./.e", work),
      await complete(files, "@../other/no", work),
      await complete(files, `@${root}/other/`, work),
    ],
    [
      {
        from: 4,
        items: [
          ["@./a.md", "@./a.md "],
          ["@./sub/", "@./sub/"],
          ['@"./my dir/"', '@"./my dir/'],
        ],
      },
      { from: 0, items: [["@./.env", "@./.env "]] },
      { from: 0, items: [["@../other/notes.md", "@../other/notes.md "]] },
      { from: 0, items: [[`@${root}/other/notes.md`, `@${root}/other/notes.md `]] },
    ],
  );
});

test("an @~/ word lists the home folder like its absolute path", async () => {
  const files = provider();
  const home = env.get("HOME") ?? "";
  const absolute = await complete(files, `@${home}/`, folder());

  assertEquals(
    await complete(files, "@~/", folder()),
    absolute && { from: 0, items: absolute.items.map((item) => item.map((text) => text.replace(home, "~"))) },
  );
});

test("an @ path to a missing folder lists nothing", async () => {
  const files = provider();

  assertEquals(await complete(files, "@./missing/", folder()), undefined);
});
