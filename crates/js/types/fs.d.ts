// The declaration of the public module `yuke:fs`.

/**
 * Files and directories. Each function gives a promise. A path is absolute, or relative to the absolute `baseDir` of
 * the options. No function uses a working folder of its own: a tool passes `context.folder`, and a plugin passes
 * `ctx.dataDir`. A failure rejects with a `FileSystemError`, and a misuse, such as a relative path without `baseDir`,
 * with a `TypeError`. An abort of the `signal` stops the operation at its next check: before each chunk of 1 MiB, and
 * before the rename of an atomic write. A stopped operation rejects with the reason of the signal. An operation that
 * finished its change before the check still fulfills. A stopped write can leave a part of the file, except an atomic
 * write. A directory or a special file, such as a FIFO, is no file: a read or a write of one rejects.
 */
declare module "yuke:fs" {
  /** The options of each function. */
  export interface FileOptions {
    /** The absolute folder that a relative path starts in. */
    baseDir?: string | undefined;
    /** A signal that stops the operation at its next check. */
    signal?: AbortSignal | undefined;
  }

  /** The options of `readFile`. */
  export interface ReadFileOptions extends FileOptions {
    /** The byte to start at. The default is 0. */
    position?: number | undefined;
    /** The most bytes to read. The default is all bytes to the end. */
    length?: number | undefined;
  }

  /** The options of `writeFile` and `writeTextFile`. */
  export interface WriteFileOptions extends FileOptions {
    /**
     * An atomic write writes a temporary file in the same folder and renames it over the path. A reader then sees the
     * old file or the new one, never a part. A crash right after the rename can still lose it, because the folder is
     * not synced. The default is `false`.
     */
    atomic?: boolean | undefined;
    /**
     * The permissions of a new file, for example `0o600`, less the bits of the umask. An atomic write without `mode`
     * keeps the permissions of the file that it replaces.
     */
    mode?: number | undefined;
  }

  /** The options of `mkdir`. */
  export interface MkdirOptions extends FileOptions {
    /** A recursive `mkdir` also makes the missing parent folders, and it accepts a folder that exists. The default is `false`. */
    recursive?: boolean | undefined;
    /** The permissions of a new folder, for example `0o700`. */
    mode?: number | undefined;
  }

  /** The options of `remove`. */
  export interface RemoveOptions extends FileOptions {
    /** A recursive `remove` also removes the entries of a directory. The default is `false`. */
    recursive?: boolean | undefined;
    /** With `force`, a path that does not exist is no failure. Each other failure still rejects. The default is `false`. */
    force?: boolean | undefined;
  }

  /** The facts of a path. */
  export interface FileInfo {
    readonly isFile: boolean;
    readonly isDirectory: boolean;
    /** `true` only for `lstat` of a symbolic link. */
    readonly isSymlink: boolean;
    /** The size in bytes. */
    readonly size: number;
    /** The time of the last change of the content, or `null` when the file system gives none. */
    readonly mtime: Date | null;
  }

  /** One entry of a directory. */
  export interface DirEntry {
    /** The name of the entry, without its folder. */
    readonly name: string;
    readonly isFile: boolean;
    readonly isDirectory: boolean;
    /** The entry is a symbolic link. `isFile` and `isDirectory` are then `false`. */
    readonly isSymlink: boolean;
  }

  /** The failure of a file operation. */
  export class FileSystemError extends Error {
    constructor(
      message: string,
      details: { readonly code: string; readonly path: string; readonly destination?: string | undefined },
    );
    /**
     * The POSIX name of the failure: `ENOENT`, `EEXIST`, `EACCES`, `EPERM`, `ENOTDIR`, `EISDIR`, `ENOTEMPTY`, `EXDEV`,
     * `ENOSPC`, `EROFS`, `ELOOP`, `ENAMETOOLONG`, `EILSEQ` (bytes or a name that are not UTF-8), `EINVAL` (a special
     * file), or `EIO` for another failure.
     */
    readonly code: string;
    /** The absolute path of the operation. */
    readonly path: string;
    /** The absolute destination of `rename`. */
    readonly destination: string | undefined;
  }

  /** The bytes of a file, or a part of them. A range that starts at or after the end gives no bytes. */
  export function readFile(path: string, options?: ReadFileOptions): Promise<Uint8Array>;
  /** The whole file as UTF-8 text. A file with bytes that are not UTF-8 rejects with `EILSEQ`. A byte order mark stays. */
  export function readTextFile(path: string, options?: FileOptions): Promise<string>;
  /** Create or replace a file with `data`. The folder of the file must exist. */
  export function writeFile(path: string, data: Uint8Array, options?: WriteFileOptions): Promise<void>;
  /** Create or replace a file with the UTF-8 bytes of `text`. A lone surrogate becomes U+FFFD. */
  export function writeTextFile(path: string, text: string, options?: WriteFileOptions): Promise<void>;
  /** The entries of a directory, without `.` and `..`, by name in JavaScript string order. */
  export function readDir(path: string, options?: FileOptions): Promise<DirEntry[]>;
  /** The facts of a path. A symbolic link gives the facts of its target. */
  export function stat(path: string, options?: FileOptions): Promise<FileInfo>;
  /** The facts of a path. A symbolic link gives the facts of the link. */
  export function lstat(path: string, options?: FileOptions): Promise<FileInfo>;
  /** Create a directory. A directory that exists rejects with `EEXIST`, unless `recursive`. */
  export function mkdir(path: string, options?: MkdirOptions): Promise<void>;
  /** Remove a file, a symbolic link (not its target), or a directory. */
  export function remove(path: string, options?: RemoveOptions): Promise<void>;
  /** Move `source` to `destination`, and replace a file there. A relative path of either starts in `baseDir`. */
  export function rename(source: string, destination: string, options?: FileOptions): Promise<void>;
}
