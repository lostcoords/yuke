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

  export const fs: {
    /** A relative path anchors at the directory the host runs in. Rejects on invalid UTF-8. */
    readFile(path: string, workspaceRoot?: string): Promise<string>;
    /** Returns an image path or bounded text with the next line after a cut. */
    readRange(path: string, range?: { start?: number | null; end?: number | null }, workspaceRoot?: string): Promise<RangeRead | { imagePath: string }>;
    /** Reads at most `maxBytes` bytes from `offset` as text, cut at a character boundary; read again from `next` to follow a growing file. */
    readFrom(path: string, offset: number, maxBytes: number, workspaceRoot?: string): Promise<{ text: string; next: number; size: number }>;
    /** Replaces the whole file and resolves the byte count. */
    writeFile(path: string, contents: string, workspaceRoot?: string): Promise<number>;
    /** Resolves null when nothing is at the path. A relative path anchors at the workspace root, or at the cwd. */
    stat(path?: string | null, workspaceRoot?: string): Promise<Stat | null>;
    /** Removes one regular file and resolves false when nothing is there. A directory or a link rejects. */
    removeFile(path: string): Promise<boolean>;
    /** Lists the directories of one path. */
    list(path?: string | null): Promise<Page>;
  };

  interface RangeRead {
    text: string;
    next: number | null;
    longLines: number;
  }
}
