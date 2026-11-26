/**
 * The bundled plugin `files`: the `@` completion of the paths in the folder of a chat session. A word that starts with
 * `@` lists the files and folders that match it. A Git folder lists what `git ls-files` gives, so ignored files stay
 * out. Another folder lists a walk that skips hidden entries, `node_modules`, and `target`. A word that starts with
 * `@./`, `@../`, `@~/`, or `@/` lists the entries of the folder that it names, also outside the session folder. The
 * draft keeps the path as plain text, and the model reads the file with its tools. A path with whitespace goes in
 * double quotes.
 */

import type { CompletionItem, CompletionList } from "yuke:chat";
import { readDir } from "yuke:fs";
import type { PluginContext } from "yuke:plugins";
import { Command, env } from "yuke:process";
import { fuzzyMatch } from "yuke:tui";

/** An `@` word at the start of the draft or after whitespace, up to the caret: an open quote with a path, or a word. */
const MENTION = /(?:^|\s)@(?:"([^"]*)|(\S*))$/;

/** An `@` word that names its folder: it starts with `./`, `../`, `~/`, or `/`. */
const PATH = /^(?:\.\.?|~)?\//;

/** The list keeps the best of the matches. */
const MOST_ITEMS = 50;

/** A walk stops after this many entries, so a huge folder does not stop the chat. */
const MOST_WALKED = 20_000;

/** The walk does not enter these folders. A Git folder follows its ignore rules instead. */
const SKIPPED = new Set(["node_modules", "target"]);

/** An index serves the asks of this many milliseconds, so a new file shows at the next mention. */
const FRESH_MS = 5000;

/** A path of an index: a folder ends with `/`. */
interface Entry {
  readonly path: string;
  readonly folder: boolean;
}

/** The paths of a folder, shallow and short first, and the build that gives the next ones. */
interface Index {
  readonly time: number;
  entries: readonly Entry[] | undefined;
  readonly ready: Promise<readonly Entry[]>;
}

/**
 * The files that Git lists below `workspace`, with the untracked files that no ignore rule takes, or `undefined` without a
 * list.
 */
async function gitFiles(workspace: string, signal: AbortSignal): Promise<string[] | undefined> {
  const args = ["ls-files", "--cached", "--others", "--exclude-standard", "-z"];
  // A folder that Git does not know, or no Git at all, gives no list.
  const output = await new Command("git", { args, cwd: workspace, stderr: "null", signal })
    .output()
    .catch(() => undefined);
  if (output === undefined || !output.success) return undefined;
  const files = new TextDecoder()
    .decode(output.stdout)
    .split("\0")
    .filter((path) => path !== "");
  // A folder that the ignore rules take, such as `target`, lists nothing, so its walk serves better.
  return files.length === 0 ? undefined : files;
}

/** The files of a walk of `workspace`, folder by folder. An unreadable folder is left out. */
async function walkedFiles(workspace: string, signal: AbortSignal): Promise<string[]> {
  const files: string[] = [];
  const folders = [""];
  let walked = 0;
  for (let folder = folders.shift(); folder !== undefined && walked < MOST_WALKED; folder = folders.shift()) {
    if (signal.aborted) break;
    const entries = await Array.fromAsync(readDir(`${workspace}/${folder}`)).catch(() => []);
    for (const entry of entries) {
      if (entry.name.startsWith(".") || SKIPPED.has(entry.name)) continue;
      walked += 1;
      if (entry.isDirectory) folders.push(`${folder}${entry.name}/`);
      else files.push(`${folder}${entry.name}`);
    }
  }
  return files;
}

/** The entries of `files` and of each folder above them, shallow and short first. */
function entriesOf(files: readonly string[]): Entry[] {
  const folders = new Set<string>();
  for (const file of files) {
    for (let end = file.indexOf("/"); end !== -1; end = file.indexOf("/", end + 1)) folders.add(file.slice(0, end + 1));
  }
  const depth = (path: string): number => path.split("/").filter((part) => part !== "").length;
  const entries = [
    ...[...folders].map((path) => ({ path, folder: true })),
    ...files.map((path) => ({ path, folder: false })),
  ];
  return entries.sort(
    (a, b) => depth(a.path) - depth(b.path) || a.path.length - b.path.length || (a.path < b.path ? -1 : 1),
  );
}

/** The best entries for `query`. The sort is stable, so equal scores keep the order of the index. */
function listOf(entries: readonly Entry[], query: string, from: number): CompletionList {
  const ranked =
    query === ""
      ? entries.slice(0, MOST_ITEMS).map((entry) => ({ entry, score: 0, ranges: undefined }))
      : entries
          .flatMap((entry) => {
            const match = fuzzyMatch(query, entry.path);
            return match === undefined ? [] : [{ entry, score: match.score, ranges: match.ranges }];
          })
          .sort((a, b) => b.score - a.score)
          .slice(0, MOST_ITEMS);
  return {
    from,
    items: ranked.map((match): CompletionItem => {
      const quoted = /\s/.test(match.entry.path);
      const label = quoted ? `@"${match.entry.path}"` : `@${match.entry.path}`;
      const shift = quoted ? 2 : 1;
      return {
        label,
        ranges: match.ranges?.map((range) => ({ from: range.from + shift, to: range.to + shift })),
        // A folder takes no space and keeps its quote open, so the list goes on into it.
        insert: match.entry.folder ? (quoted ? label.slice(0, -1) : label) : `${label} `,
      };
    }),
  };
}

/** The list of the entries of the folder that the path `query` names, or `undefined` when yuke cannot read it. */
async function listFolder(query: string, from: number, workspace: string): Promise<CompletionList | undefined> {
  const folder = query.slice(0, query.lastIndexOf("/") + 1);
  // `readDir` resolves `./`, `../`, and `/`. Only `~/` needs the home folder.
  const path = folder.startsWith("~/") ? `${env.get("HOME")}${folder.slice(1)}` : folder;
  const found = await Array.fromAsync(readDir(path, { folder: workspace })).catch(() => undefined);
  if (found === undefined) return undefined;
  // Hidden entries show only when the name starts with `.`, so `@~/` does not open on dotfiles.
  const hidden = query.startsWith(".", folder.length);
  const entries = found
    .filter((entry) => hidden || !entry.name.startsWith("."))
    .map((entry) => ({ path: `${folder}${entry.name}${entry.isDirectory ? "/" : ""}`, folder: entry.isDirectory }));
  return listOf(entries, query, from);
}

export function apply(ctx: PluginContext): undefined {
  const indexes = new Map<string, Index>();
  /** The index of `workspace`. A stale index answers while the next one builds. */
  const indexOf = (workspace: string): Index => {
    const now = Date.now();
    const known = indexes.get(workspace);
    if (known !== undefined && now - known.time < FRESH_MS) return known;
    // The build serves the next asks too, so a change of the draft does not stop it. The stop of the plugin does.
    const ready = (async () => {
      const files = (await gitFiles(workspace, ctx.signal)) ?? (await walkedFiles(workspace, ctx.signal));
      // Quotes hold a path with whitespace, and no escape lets them hold a quote too.
      return entriesOf(files.filter((file) => !(/\s/.test(file) && file.includes('"'))));
    })();
    const index: Index = { time: now, entries: known?.entries, ready };
    void ready.then((entries) => {
      index.entries = entries;
    });
    indexes.set(workspace, index);
    return index;
  };
  ctx.get("chat").addCompletionProvider({
    complete: (context) => {
      const word = MENTION.exec(context.text.slice(0, context.caret));
      if (word === null) return undefined;
      const query = word[1] ?? word[2] ?? "";
      const from = context.caret - word[0].trimStart().length;
      if (PATH.test(query)) return listFolder(query, from, context.folder);
      const index = indexOf(context.folder);
      if (index.entries !== undefined) return listOf(index.entries, query, from);
      return index.ready.then((entries) => listOf(entries, query, from));
    },
  });
  return undefined;
}
