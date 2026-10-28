/** The code of the public module `yuke:fs`. Its declaration is `types/fs.d.ts`, and the check at the end compares the two. */

import { signalOf, underSignal } from "yuke:internal/events";
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
import { fieldsOf } from "yuke:internal/values";
import { checkUint8Array, domString, usvString } from "yuke:internal/webidl";

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

/** The common options: the folder of a relative path, and the signal. */
interface Common {
  readonly baseDir: string | undefined;
  readonly signal: AbortSignal | undefined;
}

/**
 * The checked fields of `options`. `options` is `undefined`, or an object with only `baseDir`, `signal`, and the
 * fields in `names`. Another value throws a `TypeError`. An unknown field and a common field of another type also
 * throw. A field that is `undefined` is missing.
 */
function optionsOf(options: unknown, names: readonly string[] = []): Readonly<Record<string, unknown>> & Common {
  // A typo of a field would otherwise change the operation without a word.
  const fields = options === undefined ? {} : fieldsOf(options, "the options", ["baseDir", "signal", ...names]);
  const { baseDir, signal } = fields;
  if (baseDir !== undefined && typeof baseDir !== "string") throw new TypeError("the option baseDir is not a string");
  return { ...fields, baseDir, signal: signalOf(signal) };
}

/** `value` as a boolean, `false` when it is missing. Another value throws a `TypeError`. */
function flag(value: unknown, name: string): boolean {
  if (value === undefined) return false;
  if (typeof value !== "boolean") throw new TypeError(`the option ${name} is not a boolean`);
  return value;
}

/** `value` as a whole number in 0..2^53-1, or `fallback` when it is missing. Another value throws a `TypeError`. */
function wholeNumber<T>(value: unknown, name: string, fallback: T): number | T {
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`the option ${name} is not a whole number in 0..2^53-1`);
  }
  return value;
}

/** `value` as permission bits in 0..0o7777, or `undefined` when it is missing. */
function modeOf(value: unknown): number | undefined {
  const mode = wholeNumber(value, "mode", undefined);
  if (mode !== undefined && mode > 0o7777) throw new TypeError("the option mode is not in 0..0o7777");
  return mode;
}

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

export async function readFile(path: string, options?: unknown): Promise<Uint8Array> {
  const fields = optionsOf(options, ["position", "length"]);
  const { baseDir, signal } = fields;
  const position = wholeNumber(fields.position, "position", 0);
  const length = wholeNumber(fields.length, "length", undefined);
  const text = domString(path);
  return await run(signal, () => fsReadFile(text, baseDir, position, length));
}

export async function readTextFile(path: string, options?: unknown): Promise<string> {
  const fields = optionsOf(options, ["fatal"]);
  const { baseDir, signal } = fields;
  const fatal = flag(fields.fatal, "fatal");
  const text = domString(path);
  return await run(signal, () => fsReadTextFile(text, baseDir, fatal));
}

/** The write of `data`, bytes or text, with the options of a write. */
async function writeData(path: string, data: Uint8Array | string, options: unknown): Promise<void> {
  const fields = optionsOf(options, ["append", "atomic", "create", "createNew", "mode"]);
  const { baseDir, signal } = fields;
  const append = flag(fields.append, "append");
  const atomic = flag(fields.atomic, "atomic");
  const create = fields.create === undefined || flag(fields.create, "create");
  const createNew = flag(fields.createNew, "createNew");
  const mode = modeOf(fields.mode);
  // A rename replaces the whole file, and it cannot check that the path is new or that it exists.
  if (atomic && append) throw new TypeError("the options atomic and append exclude each other");
  if (atomic && createNew) throw new TypeError("the options atomic and createNew exclude each other");
  if (atomic && !create) throw new TypeError("an atomic write needs create");
  const placement = atomic ? "atomic" : append ? "append" : "replace";
  const creation = createNew ? "new" : create ? "create" : "existing";
  const text = domString(path);
  await run(signal, () => fsWriteFile(text, baseDir, data, placement, creation, mode));
}

export async function writeFile(path: string, data: Uint8Array, options?: unknown): Promise<void> {
  checkUint8Array(data, "the data");
  await writeData(path, data, options);
}

export async function writeTextFile(path: string, text: string, options?: unknown): Promise<void> {
  await writeData(path, usvString(text), options);
}

export async function readDir(
  path: string,
  options?: unknown,
): Promise<{ name: string; isFile: boolean; isDirectory: boolean; isSymlink: boolean }[]> {
  const { baseDir, signal } = optionsOf(options);
  const text = domString(path);
  const entries = await run(signal, () => fsReadDir(text, baseDir));
  return entries
    .map((entry) => ({
      name: entry.name,
      isFile: entry.isFile,
      isDirectory: entry.isDirectory,
      isSymlink: entry.isSymlink,
    }))
    .sort((first, second) => (first.name < second.name ? -1 : first.name > second.name ? 1 : 0));
}

/** The facts of `path`, through or without a follow of a symbolic link. */
async function info(path: string, options: unknown, follow: boolean) {
  const { baseDir, signal } = optionsOf(options);
  const text = domString(path);
  const facts = await run(signal, () => fsStat(text, baseDir, follow));
  return {
    isFile: facts.isFile,
    isDirectory: facts.isDirectory,
    isSymlink: facts.isSymlink,
    size: facts.size,
    mtime: facts.mtime === undefined ? null : new Date(facts.mtime),
  };
}

export async function stat(path: string, options?: unknown) {
  return await info(path, options, true);
}

export async function lstat(path: string, options?: unknown) {
  return await info(path, options, false);
}

export async function mkdir(path: string, options?: unknown): Promise<void> {
  const fields = optionsOf(options, ["recursive", "mode"]);
  const { baseDir, signal } = fields;
  const recursive = flag(fields.recursive, "recursive");
  const mode = modeOf(fields.mode);
  const text = domString(path);
  await run(signal, () => fsMkdir(text, baseDir, recursive, mode));
}

export async function remove(path: string, options?: unknown): Promise<void> {
  const fields = optionsOf(options, ["recursive", "force"]);
  const { baseDir, signal } = fields;
  const recursive = flag(fields.recursive, "recursive");
  const force = flag(fields.force, "force");
  const text = domString(path);
  await run(signal, () => fsRemove(text, baseDir, recursive, force));
}

export async function rename(source: string, destination: string, options?: unknown): Promise<void> {
  const { baseDir, signal } = optionsOf(options);
  const from = domString(source);
  const to = domString(destination);
  await run(signal, () => fsRename(from, to, baseDir));
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
