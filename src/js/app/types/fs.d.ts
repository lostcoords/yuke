declare module "yuke:fs" {
  interface Stat {
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

  export const fs: {
    /** A relative path anchors at the directory the host runs in. Rejects on invalid UTF-8. */
    readFile(path: string, workspaceRoot?: string): Promise<string>;
    /** Reads bounded whole lines and reports the next line when a limit stops the read. */
    readRange(path: string, range?: { start?: number | null; end?: number | null }, workspaceRoot?: string): Promise<RangeRead>;
    /** Replaces the whole file and resolves the byte count. */
    writeFile(path: string, contents: string, workspaceRoot?: string): Promise<number>;
    /** Resolves null when nothing is at the path. */
    stat(path?: string | null): Promise<Stat | null>;
    /** Lists the directories of one path as JSON text of a `Page`. */
    list(path?: string | null): Promise<string>;
  };

  interface RangeRead {
    text: string;
    next: number | null;
    longLines: number;
  }
}
