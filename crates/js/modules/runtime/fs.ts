/** The code of the public module `yuke:fs`. Its declaration is `types/fs.d.ts`, and the check at the end compares the two. */

import type {
  DirEntry,
  FileOptions,
  MkdirOptions,
  ReadFileOptions,
  ReadTextFileOptions,
  RemoveOptions,
  WriteFileOptions,
} from "yuke:fs";
import { underSignal } from "yuke:internal/events";
import {
  fsMkdir,
  fsReadDir,
  fsReadFile,
  fsReadTextFile,
  fsRemove,
  fsRename,
  fsStat,
  fsWriteFile,
  type Operation,
} from "yuke:internal/native";
import { usvString } from "yuke:internal/webidl";

export class FileSystemError extends Error {
  readonly code: string;
  readonly path: string;
  readonly destination: string | undefined;

  constructor(
    message: string,
    details: { readonly code: string; readonly path: string; readonly destination?: string | undefined },
  ) {
    super(message);
    this.code = details.code;
    this.path = details.path;
    this.destination = details.destination;
  }
}
FileSystemError.prototype.name = "FileSystemError";

/**
 * Run the operation of `start` under `signal`. An aborted signal rejects before the start, and an abort during the
 * operation stops it at its next check. A failure record becomes a `FileSystemError`.
 */
async function run<T>(signal: AbortSignal | undefined, start: () => Operation<T>): Promise<T> {
  // The reason of an abort before the start is no failure record, so it stays out of `failureOf`.
  signal?.throwIfAborted();
  try {
    return await underSignal(signal, start);
  } catch (error) {
    throw failureOf(error, signal);
  }
}

/** The value that a failed operation rejects with, from the record of the native, or `error` as it is. */
function failureOf(error: unknown, signal: AbortSignal | undefined): unknown {
  if (typeof error !== "object" || error === null || error instanceof Error) return error;
  const record = error as Readonly<Record<string, unknown>>;
  if (record.cancelled === true && signal !== undefined) return signal.reason;
  return new FileSystemError(String(record.message), {
    code: String(record.code),
    path: String(record.path),
    destination: typeof record.destination === "string" ? record.destination : undefined,
  });
}

export async function readFile(path: string, options: ReadFileOptions = {}): Promise<Uint8Array> {
  const { cwd, signal, position = 0, length } = options;
  return await run(signal, () => fsReadFile(path, cwd, position, length));
}

export async function readTextFile(path: string, options: ReadTextFileOptions = {}): Promise<string> {
  const { cwd, signal, fatal = false } = options;
  return await run(signal, () => fsReadTextFile(path, cwd, fatal));
}

/** The write of `data`, bytes or text, with the options of a write. */
async function writeData(path: string, data: Uint8Array | string, options: WriteFileOptions = {}): Promise<void> {
  const { cwd, signal, append = false, atomic = false, create = true, createNew = false, mode } = options;
  // A rename replaces the whole file, and it cannot check that the path is new or that it exists.
  if (atomic && append) throw new TypeError("the options atomic and append exclude each other");
  if (atomic && createNew) throw new TypeError("the options atomic and createNew exclude each other");
  if (atomic && !create) throw new TypeError("an atomic write needs create");
  const placement = atomic ? "atomic" : append ? "append" : "replace";
  const creation = createNew ? "new" : create ? "create" : "existing";
  await run(signal, () => fsWriteFile(path, cwd, data, placement, creation, mode));
}

export async function writeFile(path: string, data: Uint8Array, options?: WriteFileOptions): Promise<void> {
  await writeData(path, data, options);
}

export async function writeTextFile(path: string, text: string, options?: WriteFileOptions): Promise<void> {
  await writeData(path, usvString(text), options);
}

export async function* readDir(path: string, options: FileOptions = {}): AsyncGenerator<DirEntry, void> {
  const { cwd, signal } = options;
  const entries = await run(signal, () => fsReadDir(path, cwd));
  yield* entries.sort((first, second) => (first.name < second.name ? -1 : first.name > second.name ? 1 : 0));
}

/** The facts of `path`, through or without a follow of a symbolic link. */
async function info(path: string, options: FileOptions, follow: boolean) {
  const { cwd, signal } = options;
  const facts = await run(signal, () => fsStat(path, cwd, follow));
  return {
    isFile: facts.isFile,
    isDirectory: facts.isDirectory,
    isSymlink: facts.isSymlink,
    size: facts.size,
    mtime: facts.mtime === undefined ? null : new Date(facts.mtime),
  };
}

export async function stat(path: string, options: FileOptions = {}) {
  return await info(path, options, true);
}

export async function lstat(path: string, options: FileOptions = {}) {
  return await info(path, options, false);
}

export async function mkdir(path: string, options: MkdirOptions = {}): Promise<void> {
  const { cwd, signal, recursive = false, mode } = options;
  await run(signal, () => fsMkdir(path, cwd, recursive, mode));
}

export async function remove(path: string, options: RemoveOptions = {}): Promise<void> {
  const { cwd, signal, recursive = false, force = false } = options;
  await run(signal, () => fsRemove(path, cwd, recursive, force));
}

export async function rename(source: string, destination: string, options: FileOptions = {}): Promise<void> {
  const { cwd, signal } = options;
  await run(signal, () => fsRename(source, destination, cwd));
}

// The check against `types/fs.d.ts` keeps this code and the declarations of the authors in step.
const declared = {
  FileSystemError,
  readFile,
  readTextFile,
  writeFile,
  writeTextFile,
  readDir,
  stat,
  lstat,
  mkdir,
  remove,
  rename,
} satisfies typeof import("yuke:fs");
void declared;
