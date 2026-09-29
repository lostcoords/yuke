declare module "yuke:internal/native/fs" {
  interface Stat {
    /** The anchored absolute path, so a caller can hand the same file to the engine. */
    path: string;
    isDirectory: boolean;
    /** The last modification time, in epoch milliseconds. */
    lastModifiedMs: number;
  }

  interface PageEntry {
    name: string;
    /** The whole path, so a caller never joins one itself. */
    path: string;
    is_git_repo: boolean;
  }

  interface Page {
    path: string;
    /** The parent directory, or null at the file-system root. */
    parent: string | null;
    entries: PageEntry[];
    /** True when the directory holds more names than one page returns. */
    more: boolean;
  }

  /** An absolute directory a relative path anchors at; the host directory without one. */
  interface RootOptions {
    workspaceRoot?: string;
  }

  /**
   * Text file access on the local file system, with no confinement. A relative path resolves against `workspaceRoot`, or the host directory without one.
   * A leading `~` expands to the home directory. A failure rejects with a sentence such as "the path does not exist".
   */
  export const fs: {
    /** Read a whole file as text. It rejects for a missing path, a directory, invalid UTF-8, or a file above 10 MiB. */
    readFile(path: string, options?: RootOptions): Promise<string>;
    /**
     * Read whole lines from the 1-based line `start` through `end`, at most 2000 lines and 64 KiB; a line above 8000 bytes is cut.
     * An image file answers its path. `next` names the first line that a limit left out, or null. `longLines` counts the cut lines.
     */
    readRange(path: string, options?: RootOptions & { start?: number | null; end?: number | null }): Promise<RangeRead | { imagePath: string }>;
    /** Replace the whole file in one atomic rename, and resolve the byte count. It creates a missing file in an existing directory. A link or a directory rejects. */
    writeFile(path: string, contents: string, options?: RootOptions): Promise<number>;
    /** Describe one path. It resolves null when nothing is at the path. An absent or empty path names the workspace root. */
    stat(path?: string | null, options?: RootOptions): Promise<Stat | null>;
    /** Remove one regular file. It resolves true after the remove and false when nothing is there. A directory or a link rejects. */
    removeFile(path: string, options?: RootOptions): Promise<boolean>;
    /** List the subdirectories of one absolute path, at most 512. Files are left out. An absent path names the host directory, and a relative path rejects. */
    list(path?: string | null): Promise<Page>;
  };

  interface RangeRead {
    text: string;
    next: number | null;
    longLines: number;
  }
}
