declare module "yuke:fs" {
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

  export const fs: {
    /** A relative path anchors at the directory the host runs in. Rejects on invalid UTF-8. */
    readFile(path: string, options?: RootOptions): Promise<string>;
    /** Returns an image path or bounded text with the next line after a cut. */
    readRange(path: string, options?: RootOptions & { start?: number | null; end?: number | null }): Promise<RangeRead | { imagePath: string }>;
    /** Replaces the whole file and resolves the byte count. */
    writeFile(path: string, contents: string, options?: RootOptions): Promise<number>;
    /** Resolves null when nothing is at the path. A relative path anchors at the workspace root, or at the cwd. */
    stat(path?: string | null, options?: RootOptions): Promise<Stat | null>;
    /** Removes one regular file and resolves false when nothing is there. A directory or a link rejects. A relative path anchors at the workspace root, or at the cwd. */
    removeFile(path: string, options?: RootOptions): Promise<boolean>;
    /** Lists the directories of one path. */
    list(path?: string | null): Promise<Page>;
  };

  interface RangeRead {
    text: string;
    next: number | null;
    longLines: number;
  }
}
